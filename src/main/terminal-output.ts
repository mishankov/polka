/** Keep a disconnected launch terminal from turning a log write into a crash dialog. */
export function protectTerminalOutput(
  stdout: NodeJS.WritableStream = process.stdout,
  stderr: NodeJS.WritableStream = process.stderr,
) {
  const onError = (error: NodeJS.ErrnoException) => {
    // macOS terminal teardown can report EIO; a closed output pipe reports EPIPE.
    // Never log here: the destination that failed is also used by console.error.
    if (error.code === 'EIO' || error.code === 'EPIPE') return;
    throw error;
  };
  stdout.on('error', onError);
  stderr.on('error', onError);
}
