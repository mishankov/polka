import { dialog, type BrowserWindow } from 'electron';
import { collectDocumentPaths } from '../services/documentFiles';
type Call = (method: string, params: any) => Promise<any>;
export async function openDroppedDocuments(call: Call, p: any, paths: string[]) {
  await call('apps.get', { appId: p.appId });
  const { files, errors } = await collectDocumentPaths(paths);
  const documents: any[] = [];
  for (const path of files) {
    try {
      documents.push(await call('docs.openPath', { appId: p.appId, path, encoding: p.encoding }));
    } catch (error) {
      errors.push({
        name: path.split('/').pop() || path,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return { documents, errors };
}
export async function chooseDocuments(window: BrowserWindow, call: Call, p: any) {
  const result = await dialog.showOpenDialog(window, {
    properties: p.folder ? ['openDirectory'] : ['openFile', 'multiSelections'],
  });
  return result.canceled ? null : openDroppedDocuments(call, p, result.filePaths);
}
