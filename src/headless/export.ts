import type { MuseSession, SessionView, TranscriptItem } from '../shared/protocol'

// Markdown export, as src/main/index.ts's `export` handler writes it: one section per item, in
// order, with no dates and no tool arguments. One change on purpose: an unnamed conversation
// takes the sidebar title mMac sends before `Muse conversation`, so the heading matches the list.

/** The heading: the session's name, then its title, then mMac's sidebar title. */
export function exportTitle(session: MuseSession, fallbackTitle?: string) {
  // One line each: a newline in a first prompt must not break the `# ` heading, and a blank
  // candidate must not hide the next one.
  const oneLine = (value?: string) => (value ?? '').replace(/\s+/g, ' ').trim()
  return (
    oneLine(session.name) || oneLine(session.title) || oneLine(fallbackTitle) || 'Muse conversation'
  )
}

function heading(item: TranscriptItem) {
  if (item.kind === 'userMessage') return 'You'
  if (item.kind === 'agentMessage') return 'Muse'
  return item.tool || item.kind
}

/** The first field with text. Output only: tool arguments and command text are never written. */
function body(item: TranscriptItem) {
  return (
    item.displayText ||
    item.text ||
    item.visibleOutput ||
    item.fallbackText ||
    item.summary?.join('\n') ||
    item.objective ||
    ''
  )
}

/** The file's text: parts joined by a blank line, and one final newline. */
export function exportMarkdown(view: SessionView, title: string) {
  const content = [
    `# ${title}`,
    `Project: ${view.session.workspaceRoot || 'None'}`,
    ...view.items.map((item) => `## ${heading(item)}\n\n${body(item)}`),
  ].join('\n\n')
  return `${content}\n`
}
