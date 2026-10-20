import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import type { AppEvent, DesktopAPI } from '../shared/protocol'

async function invoke<T>(channel: string, ...args: unknown[]): Promise<T> {
  const reply: { ok: true; value: T } | { ok: false; error: string } = await ipcRenderer.invoke(
    `muse:${channel}`,
    ...args,
  )
  if (!reply.ok) throw new Error(reply.error)
  return reply.value
}

const api: DesktopAPI = {
  updateStatus: () => invoke('update-status'),
  checkForUpdates: () => invoke('check-updates'),
  setAutomaticUpdateChecks: (enabled) => invoke('automatic-updates', enabled),
  bootstrap: () => invoke('bootstrap'),
  connect: () => invoke('connect'),
  chooseCli: () => invoke('choose-cli'),
  chooseProject: () => invoke('choose-project'),
  savePreferences: (patch) => invoke('preferences', patch),
  listSessions: (cursor) => invoke('sessions', cursor),
  createSession: (project, modelId) => invoke('create', project, modelId),
  openSession: (sessionId) => invoke('open', sessionId),
  send: (input) => invoke('send', input),
  cancel: (sessionId) => invoke('cancel', sessionId),
  compact: (sessionId) => invoke('compact', sessionId),
  renameSession: (sessionId, name) => invoke('rename', sessionId, name),
  models: (sessionId) => invoke('models', sessionId),
  setModel: (sessionId, modelId) => invoke('set-model', sessionId, modelId),
  approve: (sessionId, approvalId, choiceId) => invoke('approve', sessionId, approvalId, choiceId),
  answer: (sessionId, userInputId, answers) => invoke('answer', sessionId, userInputId, answers),
  cancelQuestion: (sessionId, userInputId) => invoke('cancel-question', sessionId, userInputId),
  chooseAttachments: () => invoke('attachments'),
  removeAttachment: (id) => invoke('remove-attachment', id),
  requestMicrophone: () => invoke('microphone'),
  transcribeVoice: (audio) => invoke('voice', audio),
  cancelVoice: () => invoke('cancel-voice'),
  gitStatus: (project) => invoke('git-status', project),
  gitDiff: (project, path) => invoke('git-diff', project, path),
  gitRawDiff: (project, path) => invoke('git-raw-diff', project, path),
  gitRevertFile: (project, path) => invoke('git-revert-file', project, path),
  gitRevertHunk: (project, path, index) => invoke('git-revert-hunk', project, path, index),
  gitStageFile: (project, path) => invoke('git-stage-file', project, path),
  listFiles: (project, directory) => invoke('files', project, directory),
  readFile: (project, path) => invoke('read-file', project, path),
  revealProject: (project) => invoke('reveal-project', project),
  openTerminal: (project, login) => invoke('terminal', project, login),
  openCli: (project) => invoke('cli-terminal', project),
  exportSession: (sessionId) => invoke('export', sessionId),
  readOutput: (sessionId, itemId) => invoke('output', sessionId, itemId),
  openExternal: (url) => invoke('external', url),
  windowAction: (action) => invoke('window-action', action),
  onEvent: (callback) => {
    const listener = (_event: IpcRendererEvent, data: AppEvent) => callback(data)
    ipcRenderer.on('muse:event', listener)
    return () => ipcRenderer.removeListener('muse:event', listener)
  },
}
contextBridge.exposeInMainWorld('muse', api)
