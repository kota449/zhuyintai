// (c) 2022 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

// [TWKeyboard] EXTRACT of upstream `OSFrameworkImpl/AppKitImpl/AppKitImpl_NSView.swift`
// (upstream commit 55e1d70d7bd9db4beab414d3e93f0ec333ade6a6).
//
// Why an extract and not the whole file: the upstream file is a grab-bag (NSAlert, NSSavePanel,
// NSTabView, NSLabelView, NSFileDragRetrieverButton, ...) and imports `OSFrameworkImplViaObjC`,
// a separate Objective-C target. The candidate window only uses `NSView.pinEdges(to:)` and the
// `NSMenu` / `NSMenuItem` builder helpers below.
//
// What is byte-for-byte upstream: the two blocks below (the "PinEdges" extension, and everything
// from "MARK: - NSMenu" up to the next MARK). What is NOT upstream: `NSMenuActionTrampoline`
// (upstream implements it in Objective-C) — see Shim/NSMenuActionTrampoline.swift, written for
// this project.
//
// The upstream `import OSFrameworkImplViaObjC` and `import SwiftExtension` lines are dropped
// (single-module target; the ObjC class is replaced by the Swift shim above).

#if canImport(AppKit)

  import AppKit

  // MARK: - NSView PinEdges API.

  extension NSView {
    public func pinEdges(to view: NSView) {
      translatesAutoresizingMaskIntoConstraints = false
      let constraints = [
        NSLayoutConstraint(
          item: self,
          attribute: .top,
          relatedBy: .equal,
          toItem: view,
          attribute: .top,
          multiplier: 1,
          constant: 0
        ),
        NSLayoutConstraint(
          item: self,
          attribute: .leading,
          relatedBy: .equal,
          toItem: view,
          attribute: .leading,
          multiplier: 1,
          constant: 0
        ),
        NSLayoutConstraint(
          item: self,
          attribute: .trailing,
          relatedBy: .equal,
          toItem: view,
          attribute: .trailing,
          multiplier: 1,
          constant: 0
        ),
        NSLayoutConstraint(
          item: self,
          attribute: .bottom,
          relatedBy: .equal,
          toItem: view,
          attribute: .bottom,
          multiplier: 1,
          constant: 0
        ),
      ]
      view.addConstraints(constraints)
    }
  }


  // MARK: - NSMenu

  extension NSMenu {
    @discardableResult
    public func appendItems(
      _ target: AnyObject? = nil,
      @ArrayBuilder<NSMenuItem?> items: () -> [NSMenuItem?]
    )
      -> NSMenu {
      let theItems = items()
      for currentItem in theItems {
        guard let currentItem = currentItem else { continue }
        addItem(currentItem)
        guard let target = target else { continue }
        currentItem.target = target
        currentItem.submenu?.propagateTarget(target)
      }
      return self
    }

    @discardableResult
    public func propagateTarget(_ obj: AnyObject?) -> NSMenu {
      for currentItem in items {
        currentItem.target = obj
        currentItem.submenu?.propagateTarget(obj)
      }
      return self
    }

    public static func buildSubMenu(
      verbatim: String?,
      @ArrayBuilder<NSMenuItem?> items: () -> [NSMenuItem?]
    )
      -> NSMenuItem? {
      guard let verbatim = verbatim, !verbatim.isEmpty else { return nil }
      let newItem = NSMenu.Item(verbatim: verbatim)
      newItem?.submenu = .init(title: verbatim).appendItems(items: items)
      return newItem
    }

    public static func buildSubMenu(
      _ title: String?,
      @ArrayBuilder<NSMenuItem?> items: () -> [NSMenuItem?]
    )
      -> NSMenuItem? {
      guard let title = title?.i18n, !title.isEmpty else { return nil }
      return buildSubMenu(verbatim: title, items: items)
    }

    public typealias Item = NSMenuItem
  }

  extension Array where Element == NSMenuItem? {
    public func propagateTarget(_ obj: AnyObject?) {
      forEach { currentItem in
        guard let currentItem = currentItem else { return }
        currentItem.target = obj
        currentItem.submenu?.propagateTarget(obj)
      }
    }
  }

  extension NSMenuItem {
    public convenience init?(verbatim: String?) {
      guard let verbatim = verbatim, !verbatim.isEmpty else { return nil }
      self.init(title: verbatim, action: nil, keyEquivalent: "")
    }

    public convenience init?(_ title: String?) {
      guard let title = title?.i18n, !title.isEmpty else { return nil }
      self.init(verbatim: title)
    }

    @discardableResult
    public func hotkey(
      _ keyEquivalent: String,
      mask: NSEvent.ModifierFlags? = nil
    )
      -> NSMenuItem {
      keyEquivalentModifierMask = mask ?? keyEquivalentModifierMask
      self.keyEquivalent = keyEquivalent
      return self
    }

    @discardableResult
    public func alternated(_ assured: Bool = true) -> NSMenuItem {
      isAlternate = assured
      keyEquivalentModifierMask = .option
      return self
    }

    @discardableResult
    public func withTarget(_ target: AnyObject?) -> NSMenuItem {
      self.target = target
      return self
    }

    @discardableResult
    public func visible(_ isVisible: Bool) -> NSMenuItem {
      isHidden = !isVisible
      return self
    }

    @discardableResult
    public func disabled(_ isDisabled: Bool) -> NSMenuItem {
      isEnabled = !isDisabled
      return self
    }

    @discardableResult
    public func state(_ givenState: Bool) -> NSMenuItem {
      state = givenState ? .on : .off
      return self
    }

    @discardableResult
    public func act(_ action: Selector) -> NSMenuItem {
      self.action = action
      return self
    }

    private static var trampolineKey: NSMutex<UInt8> = .init(0)

    @discardableResult
    public func act(_ block: @escaping ((() -> ())?) -> ()) -> NSMenuItem {
      Self.trampolineKey.withLock { key in
        let oldTrampoline = objc_getAssociatedObject(self, &key) as? NSMenuActionTrampoline
        let oldBlock = oldTrampoline?.actionBlock
        objc_setAssociatedObject(self, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let trampoline = NSMenuActionTrampoline(block: { block(oldBlock) })
        self.target = trampoline
        self.action = #selector(NSMenuActionTrampoline.fire(_:))
        objc_setAssociatedObject(self, &key, trampoline, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      }
      return self
    }

    @discardableResult
    public func nulled(_ condition: Bool) -> NSMenuItem? {
      condition ? nil : self
    }

    @discardableResult
    public func mask(_ flags: NSEvent.ModifierFlags) -> NSMenuItem {
      keyEquivalentModifierMask = flags
      return self
    }

    @discardableResult
    public func represent(_ object: Any?) -> NSMenuItem {
      representedObject = object
      return self
    }

    @discardableResult
    public func tag(_ givenTag: Int?) -> NSMenuItem {
      guard let givenTag = givenTag else { return self }
      tag = givenTag
      return self
    }
  }

#endif
