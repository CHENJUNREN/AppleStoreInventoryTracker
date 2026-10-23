// Compiled with the production activity views by scripts/test-activity-ui.sh.
enum Probe { static var rows = 0 }
@main struct Perf {
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  var entries: [TaskActivity] = []
  for i in 0..<200 { entries.append(TaskActivity(kind: .information, message: "查询完成 · \(i) 家门店可取货")) }
  let view = NSHostingView(rootView: TaskActivityList(entries: entries))
  let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 600,height: 280),styleMask: [.borderless],backing: .buffered,defer: false)
  window.contentView = view
  window.orderFront(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.8))
  if #available(macOS 15.0, *) { precondition(Probe.rows < 80, "only visible rows should render") }
  print("PASS: visible row rendering (\(Probe.rows) evaluations for 200 records)")
  func findScroll(_ node: NSView) -> NSScrollView? {
   if let scroll = node as? NSScrollView { return scroll }
   for child in node.subviews { if let scroll = findScroll(child) { return scroll } }
   return nil
  }
  if let scroll = findScroll(view) {
   let initial = scroll.contentView.bounds.origin.y
   scroll.contentView.scroll(to: .zero)
   scroll.reflectScrolledClipView(scroll.contentView)
   RunLoop.main.run(until: Date().addingTimeInterval(0.2))
   let before = scroll.contentView.bounds.origin.y
   entries.append(TaskActivity(kind: .warning, message: "需要登录"))
   view.rootView = TaskActivityList(entries: entries)
   RunLoop.main.run(until: Date().addingTimeInterval(0.3))
   let after = scroll.contentView.bounds.origin.y
   print("Initial scroll offset: \(initial); history offset before/after append: \(before)/\(after)")
   fflush(stdout)
   precondition(initial > 0 && abs(before - after) < 2, "history scroll position must remain stable")
  } else { fatalError("No scroll view found") }
  window.orderOut(nil)
 }
}
