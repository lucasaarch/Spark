import SwiftUI

struct WorkspaceTabDropDelegate: DropDelegate {
    let tabID: UUID
    let tabWidth: CGFloat
    let workspace: Workspace
    let paneDrag: PaneDragState

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [PaneDragState.tabContentType]),
            let sourceTabID = paneDrag.sourceTabID {
            return workspace.canReorderTab(sourceTabID, onto: tabID)
        }
        guard info.hasItemsConforming(to: [PaneDragState.contentType]),
            let sourceID = paneDrag.sourceID else { return false }
        return workspace.canMovePane(sourceID, toTab: tabID)
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        paneDrag.showTabTarget(tabID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            paneDrag.clearTabTarget(tabID)
            return DropProposal(operation: .cancel)
        }
        paneDrag.showTabTarget(tabID)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { paneDrag.clearTabTarget(tabID) }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [PaneDragState.tabContentType]),
            let sourceTabID = paneDrag.sourceTabID {
            return workspace.reorderTab(sourceTabID, relativeTo: tabID, after: info.location.x >= tabWidth / 2)
        }
        guard validateDrop(info: info), let sourceID = paneDrag.sourceID else { return false }
        return workspace.movePane(sourceID, toTab: tabID)
    }
}
