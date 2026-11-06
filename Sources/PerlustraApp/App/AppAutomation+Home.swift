import AppKit

#if DEBUG
    /// Scripted steps for the start page and the template library.
    extension AppAutomation {
        func runHomeCommand(_ command: String, _ wc: ViewerWindowController) async {
            let canvas = guillocheCanvas(in: wc.window?.contentView)
            switch command {
            case let c where c.hasPrefix("homelens:"):
                let at = c.dropFirst(9).split(separator: ",").compactMap { Float($0) }
                if at.count == 2, let canvas {
                    canvas.follow(SIMD2(at[0], at[1]))
                    await sleep(0.05)
                    canvas.finishMotion()
                }
            case "homerest":
                canvas?.pointerLeft()
            case "homefront":
                // Comes forward without taking the keyboard, to see frames really reach the screen.
                wc.window?.orderFrontRegardless()
                await sleep(2.2)
                print("HOMEFRONT frames", canvas?.framesDrawn ?? -1, "visible", wc.window?.occlusionState.contains(.visible) ?? false)
                canvas?.follow(SIMD2(700, 120))
                await sleep(0.9)
                print("HOMEFRONT after pointer frames", canvas?.framesDrawn ?? -1)
                await sleep(0.5)
                let settled = canvas?.framesDrawn ?? -1
                await sleep(0.5)
                print("HOMEFRONT idle frames", settled, canvas?.framesDrawn ?? -1)
            case "homestill":
                canvas?.finishMotion()
            case let c where c.hasPrefix("homepng:"):
                canvas?.finishMotion()
                canvas?.writeStill(to: URL(fileURLWithPath: String(c.dropFirst(8))))
            case let c where c.hasPrefix("template:"):
                let wanted = String(c.dropFirst(9))
                if let template = MarkdownTemplates.all().first(where: { $0.title == wanted }),
                    let url = try? MarkdownDrafts.create(named: template.title, content: template.document())
                {
                    _ = await load(url, wc)
                }
            case "templates":
                AppDelegate.shared?.showTemplates(nil)
                await sleep(0.5)
                captureOverride = TemplatesWindow.window
            default:
                break
            }
        }

        private func guillocheCanvas(in view: NSView?) -> GuillocheCanvasView? {
            guard let view else { return nil }
            if let found = view as? GuillocheCanvasView, !found.isHiddenOrHasHiddenAncestor { return found }
            for sub in view.subviews { if let found = guillocheCanvas(in: sub) { return found } }
            return nil
        }
    }
#endif
