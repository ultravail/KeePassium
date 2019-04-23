//
//  PopoverAnchor.swift
//  KeePassium
//
//  Created by Andrei Popleteev on 2019-02-16.
//  Copyright © 2019 Andrei Popleteev. All rights reserved.
//

import UIKit

/// A universal popover anchor, suitable both for bar buttons and general views.
struct PopoverAnchor {
    enum Kind {
        /// `barButtonItem` is guaranteed to be set.
        case barButton
        /// Both `sourceView` and `sourceRect` are guaranteed to be set.
        case viewRect
    }
    public let kind: Kind
    public let barButtonItem: UIBarButtonItem?
    public let sourceView: UIView?
    public let sourceRect: CGRect?
    
    init(barButtonItem: UIBarButtonItem) {
        self.kind = .barButton
        self.barButtonItem = barButtonItem
        self.sourceView = nil
        self.sourceRect = nil
    }
    
    init(sourceView: UIView, sourceRect: CGRect) {
        self.kind = .viewRect
        self.barButtonItem = nil
        self.sourceView = sourceView
        self.sourceRect = sourceRect
    }
    
    public func apply(to popover: UIPopoverPresentationController) {
        switch kind {
        case .barButton:
            assert(barButtonItem != nil)
            popover.barButtonItem = barButtonItem
        case .viewRect:
            assert(sourceView != nil && sourceRect != nil)
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect!
        }
    }
}