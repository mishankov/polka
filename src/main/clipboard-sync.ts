import { promises as fs } from 'node:fs';
import { dirname } from 'node:path';
import { hostname } from 'node:os';
import { randomBytes, timingSafeEqual, X509Certificate } from 'node:crypto';
import * as https from 'node:https';
import * as tls from 'node:tls';
import type { Socket } from 'node:net';
import type { IncomingMessage } from 'node:http';
import { spawn, type ChildProcess } from 'node:child_process';
import { createInterface, type Interface } from 'node:readline';
import { isIP } from 'node:net';
import { generate } from 'selfsigned';
import { z } from 'zod';
import { ClipboardHistory, MAX_CLIP_BYTES } from './clipboard-history';
import type { ClipboardSyncState } from '../shared/clipboard';

const idSchema = z.string().uuid();
const tokenSchema = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const fingerprintSchema = z.string().regex(/^(?:[A-F0-9]{2}:){31}[A-F0-9]{2}$/);
const peerSchema = z.object({
  id: idSchema,
  name: z.string().min(1).max(100),
  token: tokenSchema,
  fingerprint: fingerprintSchema,
});
const credentialsSchema = z.object({
  enabled: z.boolean(),
  key: z.string(),
  cert: z.string(),
  peers: z.array(peerSchema).max(32),
});
type Peer = z.infer<typeof peerSchema>;
const MAX_WIRE_BYTES = MAX_CLIP_BYTES * 6 + 2 * 1024 * 1024;
const MAX_MANIFEST_BYTES = 16 * 1024 * 1024;
function equal(a: string, b: string) {
  const left = Buffer.from(a),
    right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}
async function readJson(message: IncomingMessage, limit: number) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of message) {
    size += chunk.length;
    if (size > limit) {
      message.destroy();
      throw Error('Слишком большой ответ синхронизации');
    }
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
}

export class ClipboardSync {
  private credentials?: z.infer<typeof credentialsSchema>;
  private server?: https.Server;
  private discovery?: ChildProcess;
  private discoveryLines?: Interface;
  private nearby = new Map<string, { name: string; host: string; port: number }>();
  private statuses = new Map<
    string,
    { status: 'offline' | 'syncing' | 'connected'; lastSync?: number; error?: string }
  >();
  private invitation?: { secret: string; expiresAt: number };
  private timer?: ReturnType<typeof setInterval>;
  private syncing?: Promise<void>;
  private sockets = new Set<Socket>();
  private stopped = false;
  private error = '';
  private queue: Promise<unknown> = Promise.resolve();
  private agents = new Set<https.Agent>();
  readonly deviceName: string;
  constructor(
    private options: {
      path: string;
      codec: { encode(value: string): Buffer; decode(value: Buffer): string };
      history: ClipboardHistory;
      changed(): void;
      discovery?: boolean;
      discoveryPath?: string;
      name?: string;
    },
  ) {
    this.deviceName = (options.name || hostname()).slice(0, 100);
  }
  private fingerprint() {
    return new X509Certificate(this.credentials!.cert).fingerprint256;
  }
  state(): ClipboardSyncState {
    const invitation =
      this.invitation && this.invitation.expiresAt > Date.now()
        ? {
            code: Buffer.from(
              JSON.stringify({
                version: 1,
                id: this.options.history.deviceId,
                fingerprint: this.fingerprint(),
                secret: this.invitation.secret,
              }),
            ).toString('base64url'),
            expiresAt: this.invitation.expiresAt,
          }
        : undefined;
    return {
      enabled: this.credentials?.enabled ?? false,
      deviceName: this.deviceName,
      nearby: Array.from(this.nearby, ([id, value]) => ({ id, name: value.name })).filter(
        ({ id }) => !this.credentials?.peers.some((peer) => peer.id === id),
      ),
      peers: (this.credentials?.peers || []).map(({ id, name }) => ({
        id,
        name,
        ...(this.statuses.get(id) || { status: 'offline' as const }),
      })),
      invitation,
      error: this.error || undefined,
    };
  }
  private async mutate(operation: () => void) {
    const result = this.queue.then(async () => {
      if (!this.credentials) throw Error('Синхронизация ещё не готова');
      const before = structuredClone(this.credentials);
      try {
        operation();
        await fs.mkdir(dirname(this.options.path), { recursive: true, mode: 0o700 });
        await fs.writeFile(
          this.options.path + '.tmp',
          this.options.codec.encode(JSON.stringify(this.credentials)),
          { mode: 0o600 },
        );
        await fs.rename(this.options.path + '.tmp', this.options.path);
      } catch (error) {
        this.credentials = before;
        throw error;
      }
      this.options.changed();
    });
    this.queue = result.catch(() => {});
    return result;
  }
  async initialize() {
    await this.options.history.persistIdentity();
    try {
      this.credentials = credentialsSchema.parse(
        JSON.parse(this.options.codec.decode(await fs.readFile(this.options.path))),
      );
    } catch (reason) {
      if ((reason as NodeJS.ErrnoException).code !== 'ENOENT') throw reason;
      const pems = await generate([{ name: 'commonName', value: 'Everything clipboard sync' }], {
        algorithm: 'sha256',
        keyType: 'ec',
        notAfterDate: new Date('2046-01-01'),
      });
      this.credentials = { enabled: false, key: pems.private, cert: pems.cert, peers: [] };
      await this.mutate(() => {});
    }
    if (this.credentials.enabled) await this.open();
  }
  async setEnabled(enabled: boolean) {
    await this.mutate(() => {
      this.credentials!.enabled = enabled;
    });
    if (enabled) {
      this.stopped = false;
      await this.open();
    } else await this.close();
  }
  invite() {
    if (!this.server || !this.credentials?.enabled) throw Error('Сначала включите синхронизацию');
    if (this.credentials.peers.length >= 32) throw Error('Можно связать не больше 32 устройств');
    this.invitation = {
      secret: randomBytes(32).toString('base64url'),
      expiresAt: Date.now() + 5 * 60000,
    };
    this.options.changed();
  }
  cancelInvite() {
    this.invitation = undefined;
    this.options.changed();
  }
  async forget(id: string) {
    await this.mutate(() => {
      this.credentials!.peers = this.credentials!.peers.filter((peer) => peer.id !== id);
    });
    this.statuses.delete(id);
    this.options.changed();
  }
  private async open() {
    if (this.server) return;
    this.error = '';
    const server = https.createServer(
      {
        key: this.credentials!.key,
        cert: this.credentials!.cert,
        minVersion: 'TLSv1.3',
        requestCert: true,
        rejectUnauthorized: false,
      },
      (request, response) => {
        void this.serve(request)
          .then((result) => {
            response.setHeader('Content-Type', 'application/json');
            response.end(JSON.stringify(result));
          })
          .catch(() => {
            if (!response.destroyed) {
              response.statusCode = 403;
              response.end('{}');
            }
          });
      },
    );
    server.maxConnections = 16;
    server.requestTimeout = 30000;
    server.headersTimeout = 10000;
    server.on('connection', (socket) => {
      this.sockets.add(socket);
      socket.once('close', () => this.sockets.delete(socket));
      socket.setTimeout(30000, () => socket.destroy());
    });
    server.on('tlsClientError', () => {});
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, () => {
        server.removeListener('error', reject);
        resolve();
      });
    });
    this.server = server;
    server.on('error', (reason) => {
      this.error = reason.message;
      this.options.changed();
    });
    if (this.options.discovery !== false) {
      if (!this.options.discoveryPath) throw Error('Наблюдение за локальной сетью недоступно');
      const discovery = spawn(
        this.options.discoveryPath,
        [this.options.history.deviceId, this.deviceName, String(this.port)],
        { stdio: ['ignore', 'pipe', 'ignore'] },
      );
      this.discovery = discovery;
      this.discoveryLines = createInterface({ input: discovery.stdout! });
      this.discoveryLines.on('line', (line) => {
        try {
          const message = JSON.parse(line);
          if (message.type === 'up') {
            const peer = z
              .object({
                id: idSchema,
                name: z.string().max(100),
                host: z.string().max(200),
                port: z.number().int().min(1).max(65535),
              })
              .parse(message);
            if (isIP(peer.host.split('%')[0]))
              this.discover(peer.id, peer.name, peer.host, peer.port);
          } else if (message.type === 'down') {
            const id = idSchema.parse(message.id);
            this.nearby.delete(id);
            const status = this.statuses.get(id);
            if (status) status.status = 'offline';
            this.options.changed();
          } else if (message.type === 'error') {
            this.error = z.string().max(500).parse(message.message);
            this.options.changed();
          }
        } catch {
          /* Ignore malformed discovery records. */
        }
      });
      const failed = () => {
        if (!this.stopped && this.discovery === discovery) {
          this.error = 'Обнаружение Mac остановлено. Выключите и снова включите синхронизацию.';
          this.options.changed();
        }
      };
      discovery.on('error', failed);
      discovery.on('exit', failed);
    }

    this.timer = setInterval(() => {
      void this.syncNow();
      this.options.changed();
    }, 3000);
    this.options.changed();
  }
  get port() {
    const address = this.server?.address();
    return address && typeof address !== 'string' ? address.port : 0;
  }
  // Also used by integration tests with independent peers on loopback.
  discover(id: string, name: string, host: string, port: number) {
    if (this.nearby.size >= 128 && !this.nearby.has(id)) return;
    this.nearby.set(id, { name, host, port });
    this.options.changed();
    void this.syncNow();
  }
  private async serve(request: IncomingMessage) {
    if (this.stopped || !this.credentials?.enabled) throw Error('Синхронизация отключена');
    const socket = request.socket as tls.TLSSocket;
    const fingerprint = socket.getPeerCertificate().fingerprint256;
    if (!fingerprint) throw Error('Нет сертификата устройства');
    const id = String(request.headers['x-everything-id'] || '');
    const token = String(request.headers['x-everything-token'] || '');
    if (request.method === 'POST' && request.url === '/pair') {
      const invitation = this.invitation;
      if (!invitation || invitation.expiresAt <= Date.now() || !equal(token, invitation.secret))
        throw Error('Код недействителен');
      // Consume before awaiting I/O: one invitation can authorize only one device.
      this.invitation = undefined;
      this.options.changed();
      const incoming = peerSchema.parse({
        ...z.object({ name: z.string(), token: tokenSchema }).parse(await readJson(request, 4096)),
        id,
        fingerprint,
      });
      if (id === this.options.history.deviceId) throw Error('Это тот же Mac');
      if (this.stopped || !this.credentials.enabled) throw Error('Синхронизация отключена');
      await this.mutate(() => {
        if (this.credentials!.peers.length >= 32) throw Error('Слишком много устройств');
        this.credentials!.peers = this.credentials!.peers.filter((peer) => peer.id !== id);
        this.credentials!.peers.push(incoming);
      });
      return { id: this.options.history.deviceId, name: this.deviceName };
    }
    const peer = this.credentials.peers.find((item) => item.id === id);
    if (!peer || !equal(peer.token, token) || !equal(peer.fingerprint, fingerprint))
      throw Error('Устройство не связано');
    if (this.options.history.getPreferences().paused) throw Error('История на паузе');
    if (request.method === 'GET' && request.url === '/manifest') {
      await this.options.history.prune();
      return this.options.history.manifest();
    }
    if (request.method === 'GET' && /^\/clip\/[a-f0-9]{64}$/.test(request.url || ''))
      return this.transfer(request.url!.slice(6)) || null;
    if (request.method === 'POST' && request.url === '/manifest') {
      const input = await readJson(request, MAX_MANIFEST_BYTES);
      if (!this.activePeer(peer)) throw Error('Устройство отвязано');
      return { missing: await this.options.history.mergeManifest(input) };
    }
    if (request.method === 'POST' && request.url === '/clip') {
      const input = await readJson(request, MAX_WIRE_BYTES);
      if (!this.activePeer(peer)) throw Error('Устройство отвязано');
      await this.options.history.receive(input, peer.name);
      return { ok: true };
    }
    throw Error('Неизвестная операция');
  }
  private request(
    peer: Pick<Peer, 'id' | 'fingerprint' | 'token'>,
    path: string,
    body?: unknown,
  ): Promise<unknown> {
    const endpoint = this.nearby.get(peer.id);
    if (!endpoint) return Promise.reject(Error('Mac не найден в локальной сети'));
    const agent = new https.Agent({ keepAlive: false });
    this.agents.add(agent);
    // Wait for a pinned TLS handshake before allowing HTTP headers or clip bytes
    // onto the socket. Both sides authenticate the other device's certificate.
    agent.createConnection = ((
      options: tls.ConnectionOptions,
      callback: (error: Error | null, socket?: tls.TLSSocket) => void,
    ) => {
      const socket = tls.connect(
        {
          ...options,
          key: this.credentials!.key,
          cert: this.credentials!.cert,
          minVersion: 'TLSv1.3',
          rejectUnauthorized: false,
        },
        () => {
          socket.removeListener('error', onHandshakeError);
          if (!equal(socket.getPeerCertificate().fingerprint256 || '', peer.fingerprint)) {
            callback(Error('Сертификат Mac изменился. Свяжите устройства заново.'));
            socket.destroy();
          } else callback(null, socket);
        },
      );
      this.sockets.add(socket);
      socket.once('close', () => this.sockets.delete(socket));
      const onHandshakeError = (error: Error) => callback(error);
      socket.once('error', onHandshakeError);
      socket.setTimeout(30000, () => socket.destroy(Error('Mac не отвечает')));
      return undefined;
    }) as typeof agent.createConnection;
    return new Promise<unknown>((resolve, reject) => {
      const request = https.request(
        {
          host: endpoint.host,
          port: endpoint.port,
          path,
          method: body === undefined ? 'GET' : 'POST',
          agent,
          headers: {
            'Content-Type': 'application/json',
            'x-everything-id': this.options.history.deviceId,
            'x-everything-token': peer.token,
          },
        },
        (response) => {
          if (response.statusCode !== 200) {
            response.resume();
            reject(
              Error(
                'Mac отклонил соединение. Проверьте, что синхронизация включена и история не на паузе.',
              ),
            );
            return;
          }
          void readJson(
            response,
            path.startsWith('/clip/') ? MAX_WIRE_BYTES : MAX_MANIFEST_BYTES,
          ).then(resolve, reject);
        },
      );
      request.once('error', reject);
      request.setTimeout(30000, () => request.destroy(Error('Mac не отвечает')));
      request.end(body === undefined ? undefined : JSON.stringify(body));
    }).finally(() => {
      agent.destroy();
      this.agents.delete(agent);
    });
  }
  async pair(code: string) {
    if (!this.server || !this.credentials?.enabled) throw Error('Сначала включите синхронизацию');
    if (this.credentials.peers.length >= 32) throw Error('Можно связать не больше 32 устройств');
    const invitation = z
      .object({
        version: z.literal(1),
        id: idSchema,
        fingerprint: fingerprintSchema,
        secret: tokenSchema,
      })
      .parse(
        JSON.parse(
          Buffer.from(z.string().max(2048).parse(code).trim(), 'base64url').toString('utf8'),
        ),
      );
    if (invitation.id === this.options.history.deviceId) throw Error('Введите код с другого Mac');
    const token = randomBytes(32).toString('base64url');
    const response = z.object({ id: idSchema, name: z.string().min(1).max(100) }).parse(
      await this.request({ ...invitation, token: invitation.secret }, '/pair', {
        name: this.deviceName,
        token,
      }),
    );
    if (this.stopped || !this.credentials.enabled) throw Error('Синхронизация отключена');
    if (response.id !== invitation.id) throw Error('Неверное устройство');
    await this.mutate(() => {
      this.credentials!.peers = this.credentials!.peers.filter((peer) => peer.id !== response.id);
      this.credentials!.peers.push({ ...response, token, fingerprint: invitation.fingerprint });
    });
    await this.syncNow();
  }
  syncNow(): Promise<void> {
    if (this.syncing) return this.syncing;
    this.syncing = this.exchange()
      .catch((reason) => {
        this.error = reason instanceof Error ? reason.message : String(reason);
        this.options.changed();
      })
      .finally(() => {
        this.syncing = undefined;
      });
    return this.syncing;
  }
  private async exchange() {
    if (this.stopped || !this.credentials?.enabled || this.options.history.getPreferences().paused)
      return;
    {
      await this.options.history.prune();
      for (const peer of [...this.credentials.peers]) {
        if (!this.nearby.has(peer.id)) continue;
        this.statuses.set(peer.id, {
          ...this.statuses.get(peer.id),
          status: 'syncing',
          error: undefined,
        });
        this.options.changed();
        try {
          const remote = await this.request(peer, '/manifest');
          if (!this.activePeer(peer)) continue;
          const missing = await this.options.history.mergeManifest(remote);
          for (const id of missing) {
            if (!this.activePeer(peer)) break;
            const transfer = await this.request(peer, `/clip/${id}`);
            if (transfer && this.activePeer(peer))
              await this.options.history.receive(transfer, peer.name);
          }
          if (!this.activePeer(peer)) continue;
          const response = z
            .object({ missing: z.array(z.string().regex(/^[a-f0-9]{64}$/)).max(200) })
            .parse(await this.request(peer, '/manifest', this.options.history.manifest()));
          for (const id of response.missing) {
            if (!this.activePeer(peer)) break;
            const transfer = this.transfer(id);
            if (transfer) await this.request(peer, '/clip', transfer);
          }
          if (this.activePeer(peer))
            this.statuses.set(peer.id, { status: 'connected', lastSync: Date.now() });
        } catch (reason) {
          if (this.activePeer(peer))
            this.statuses.set(peer.id, {
              ...this.statuses.get(peer.id),
              status: 'offline',
              error: reason instanceof Error ? reason.message : String(reason),
            });
        }
        this.options.changed();
      }
    }
  }
  private transfer(id: string) {
    const transfer = this.options.history.transfer(id);
    if (transfer) transfer.clip.sourceDevice ||= this.deviceName;
    return transfer;
  }
  private activePeer(peer: Peer) {
    return (
      !this.stopped &&
      this.credentials?.enabled &&
      !this.options.history.getPreferences().paused &&
      this.credentials.peers.some((item) => item.id === peer.id && item.token === peer.token)
    );
  }
  private async close() {
    this.stopped = true;
    clearInterval(this.timer);
    this.invitation = undefined;
    this.discoveryLines?.close();
    this.discoveryLines = undefined;
    this.discovery?.kill();
    this.discovery = undefined;
    this.nearby.clear();
    for (const agent of this.agents) agent.destroy();
    for (const socket of this.sockets) socket.destroy();
    this.statuses.clear();
    const server = this.server;
    this.server = undefined;
    if (server) {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
    this.options.changed();
  }
  async stop() {
    await this.close();
    await this.syncing;
    await this.queue;
  }
}
