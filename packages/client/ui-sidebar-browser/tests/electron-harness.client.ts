/** Native webview events controlled by each test; presentation and navigation stay real. */
import { vi } from 'vitest'
import type { Mock } from 'vitest'
import type { DesktopBrowserBridge, DesktopBrowserLeaseId, DesktopBrowserReservation } from '../src/types.ts'
import type { BrowserTabState } from '../src/client/browser/BrowserPersistence.ts'
import { createElectronPage } from '../src/client/electron/pages.ts'
import { ElectronWebviewPresentation } from '../src/client/electron/ElectronWebviewPresentation.ts'

let sequence = 0

/**
 * @returns one isolated, explicitly mounted page with native operations replaced by spies. The mocks
 *   are annotated because vitest 5's inferred `Mock` instances embed a non-portable internal type.
 */
export function electronFixture(initial?: BrowserTabState) {
  const opens = new Set<(url: string) => void>()
  const reservation: DesktopBrowserReservation = { lease: `lease-${++sequence}` as DesktopBrowserLeaseId, partition: 'partition' }
  const bridge = {
    acquire: vi.fn(async (_workspace: string) => reservation) as Mock,
    release: vi.fn(async (_lease: DesktopBrowserLeaseId) => {}) as Mock,
    onOpenRequested: vi.fn((_lease: DesktopBrowserLeaseId, listener: (url: string) => void) => {
      opens.add(listener)
      return () => { opens.delete(listener) }
    }) as Mock,
  } satisfies DesktopBrowserBridge
  const workspace: Mock = vi.fn(async (_signal: AbortSignal) => 'cwd:/workspace')
  const persist: Mock = vi.fn()
  const openRequested: Mock = vi.fn()
  const page = createElectronPage({ initial, persist, openRequested }, bridge, workspace)
  const presentation = page.presentation
  if (!(presentation instanceof ElectronWebviewPresentation)) throw new Error('expected the Electron presentation')
  const create = presentation.createElement.bind(presentation)
  const guests: ReturnType<typeof prepareGuest>[] = []
  function prepareGuest(approved: DesktopBrowserReservation) {
    const element = create(approved)
    const state = { url: 'about:blank', title: '', loading: true, back: false, forward: false }
    const methods = {
      loadURL: vi.fn(async (_url: string) => {}) as Mock,
      getURL: vi.fn(() => state.url) as Mock, getTitle: vi.fn(() => state.title) as Mock,
      canGoBack: () => state.back, canGoForward: () => state.forward, clearHistory: vi.fn() as Mock,
      goBack: vi.fn() as Mock, goForward: vi.fn() as Mock, reload: vi.fn() as Mock, isLoading: () => state.loading,
    }
    Object.assign(element, methods)
    const emit = (type: string, fields: object = {}): void => { element.dispatchEvent(Object.assign(new Event(type), fields)) }
    return { element, state, emit, ...methods }
  }
  const createElement = vi.spyOn(presentation, 'createElement').mockImplementation((approved) => {
    const guest = prepareGuest(approved)
    guests.push(guest)
    return guest.element
  })
  const host = document.createElement('div')
  host.id = `electron-fixture-${sequence}`
  document.body.append(host)
  return {
    ...page, presentation, bridge, workspace, persist, openRequested, opens, guests, host, reservation,
    mount: () => presentation.mount(host.id),
    async guest() {
      await vi.waitFor(() => { expectGuest() })
      return guests.at(-1)!
    },
    async dispose() {
      await page.frame.dispose()
      createElement.mockRestore()
      host.remove()
    },
  }
  function expectGuest(): void {
    if (host.firstElementChild === null || guests.length === 0) throw new Error('guest has not attached')
  }
}
