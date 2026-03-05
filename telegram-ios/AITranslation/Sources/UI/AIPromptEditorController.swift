import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import UndoUI

public func aiPromptEditorController(context: AccountContext, direction: String) -> ViewController {
    let controller = AIPromptEditorViewController(context: context, direction: direction)
    return controller
}

private final class AIPromptEditorViewController: ViewController {
    private let context: AccountContext
    private let direction: String
    private var textView: UITextView?
    private var loadingLabel: UILabel?
    private var loadDisposable: Disposable?
    private var saveDisposable: Disposable?
    private var isSaving: Bool = false

    init(context: AccountContext, direction: String) {
        self.context = context
        self.direction = direction
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            presentationData: presentationData
        ))
        if direction == "outgoing" {
            self.title = "Outgoing Prompt (EN>DE)"
        } else {
            self.title = "Incoming Prompt (DE>EN)"
        }
        self.navigationItem.setRightBarButton(UIBarButtonItem(
            title: "Save",
            style: .done,
            target: self,
            action: #selector(saveTapped)
        ), animated: false)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadDisposable?.dispose()
        saveDisposable?.dispose()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
    }

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()

        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor

        let loading = UILabel()
        loading.text = "Loading prompt..."
        loading.textColor = presentationData.theme.list.itemSecondaryTextColor
        loading.font = UIFont.systemFont(ofSize: 15)
        loading.textAlignment = .center
        self.displayNode.view.addSubview(loading)
        self.loadingLabel = loading

        let tv = UITextView()
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textColor = presentationData.theme.list.itemPrimaryTextColor
        tv.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        tv.layer.cornerRadius = 10
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.alpha = 0
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        self.displayNode.view.addSubview(tv)
        self.textView = tv

        self.loadDisposable = (AITranslationService.shared.getPrompt(direction: self.direction)
        |> deliverOnMainQueue).startStrict(next: { [weak self] prompt in
            guard let self = self else { return }
            self.loadingLabel?.removeFromSuperview()
            self.textView?.text = prompt
            UIView.animate(withDuration: 0.2) {
                self.textView?.alpha = 1
            }
        })
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        let navBarHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        let insets = layout.safeInsets
        let padding: CGFloat = 16
        let contentTop = navBarHeight + padding
        let contentFrame = CGRect(
            x: insets.left + padding,
            y: contentTop,
            width: layout.size.width - insets.left - insets.right - padding * 2,
            height: layout.size.height - contentTop - insets.bottom - padding
        )

        if let textView = self.textView {
            transition.updateFrame(view: textView, frame: contentFrame)
        }
        if let loadingLabel = self.loadingLabel {
            loadingLabel.frame = contentFrame
        }
    }

    @objc private func saveTapped() {
        // Prevent double-tap while save is in-flight
        guard !isSaving else { return }

        guard let text = textView?.text else { return }

        // Validate minimum length
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else {
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let undoController = UndoOverlayController(
                presentationData: presentationData,
                content: .info(
                    title: nil,
                    text: "Prompt too short (minimum 10 characters)",
                    timeout: nil,
                    customUndoText: nil
                ),
                elevatedLayout: false,
                action: { _ in return false }
            )
            self.context.sharedContext.mainWindow?.present(undoController, on: .root)
            return
        }

        isSaving = true
        self.navigationItem.rightBarButtonItem?.isEnabled = false

        self.saveDisposable = (AITranslationService.shared.setPrompt(text, direction: self.direction)
        |> deliverOnMainQueue).startStrict(next: { [weak self] success in
            guard let self = self else { return }
            self.isSaving = false
            self.navigationItem.rightBarButtonItem?.isEnabled = true

            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let message = success ? "Prompt saved" : "Failed to save prompt"
            let undoController = UndoOverlayController(
                presentationData: presentationData,
                content: .info(
                    title: nil,
                    text: message,
                    timeout: nil,
                    customUndoText: nil
                ),
                elevatedLayout: false,
                action: { _ in return false }
            )
            self.context.sharedContext.mainWindow?.present(undoController, on: .root)

            if success {
                self.navigationController?.popViewController(animated: true)
            }
        })
    }
}
