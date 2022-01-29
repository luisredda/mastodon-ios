//
//  ThreadViewModel+Diffable.swift
//  Mastodon
//
//  Created by MainasuK Cirno on 2021-4-12.
//

import UIKit
import Combine
import CoreData
import CoreDataStack
import MastodonSDK

extension ThreadViewModel {
    
    @MainActor
    func setupDiffableDataSource(
        tableView: UITableView,
        statusTableViewCellDelegate: StatusTableViewCellDelegate
    ) {
        diffableDataSource = StatusSection.diffableDataSource(
            tableView: tableView,
            context: context,
            configuration: StatusSection.Configuration(
                statusTableViewCellDelegate: statusTableViewCellDelegate,
                timelineMiddleLoaderTableViewCellDelegate: nil
            )
        )
        
        // make initial snapshot animation smooth
        var snapshot = NSDiffableDataSourceSnapshot<StatusSection, StatusItem>()
        snapshot.appendSections([.main])
        if let root = self.root {
            if case let .root(threadContext) = root,
               let status = threadContext.status.object(in: context.managedObjectContext),
               status.inReplyToID != nil
            {
                snapshot.appendItems([.topLoader], toSection: .main)
            }
            
            snapshot.appendItems([.thread(root)], toSection: .main)
        } else {
            
        }
        diffableDataSource?.apply(snapshot, animatingDifferences: false)
        
        $threadContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threadContext in
                guard let self = self else { return }
                guard let _ = threadContext else {
                    return
                }

                self.loadThreadStateMachine.enter(LoadThreadState.Loading.self)
            }
            .store(in: &disposeBag)

        Publishers.CombineLatest3(
            $root,
            mastodonStatusThreadViewModel.$ancestors,
            mastodonStatusThreadViewModel.$descendants
        )
        .throttle(for: 1, scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] root, ancestors, descendants in
            guard let self = self else { return }
            guard let diffableDataSource = self.diffableDataSource else { return }
            
            Task { @MainActor in
                let oldSnapshot = diffableDataSource.snapshot()

                var newSnapshot = NSDiffableDataSourceSnapshot<StatusSection, StatusItem>()
                newSnapshot.appendSections([.main])

                // top loader
                let _hasReplyTo: Bool? = try? await self.context.managedObjectContext.perform {
                    guard case let .root(threadContext) = root else { return nil }
                    guard let status = threadContext.status.object(in: self.context.managedObjectContext) else { return nil }
                    return status.inReplyToID != nil
                }
                if let hasReplyTo = _hasReplyTo, hasReplyTo {
                    let state = self.loadThreadStateMachine.currentState
                    if state is LoadThreadState.NoMore {
                        // do nothing
                    } else {
                        newSnapshot.appendItems([.topLoader], toSection: .main)
                    }
                }
                
                // replies
                newSnapshot.appendItems(ancestors.reversed(), toSection: .main)
                // root
                if let root = root {
                    let item = StatusItem.thread(root)
                    newSnapshot.appendItems([item], toSection: .main)
                }
                // leafs
                newSnapshot.appendItems(descendants, toSection: .main)
                // bottom loader
                if let currentState = self.loadThreadStateMachine.currentState {
                    switch currentState {
                    case is LoadThreadState.Initial,
                        is LoadThreadState.Loading,
                        is LoadThreadState.Fail:
                        newSnapshot.appendItems([.bottomLoader], toSection: .main)
                    default:
                        break
                    }
                }
                
                let hasChanges = newSnapshot.itemIdentifiers != oldSnapshot.itemIdentifiers
                if !hasChanges {
                    self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): snapshot not changes")
                    return
                } else {
                    self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): snapshot has changes")
                }
                
                guard let difference = self.calculateReloadSnapshotDifference(
                    tableView: tableView,
                    oldSnapshot: oldSnapshot,
                    newSnapshot: newSnapshot
                ) else {
                    await self.updateDataSource(snapshot: newSnapshot, animatingDifferences: false)
                    self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): applied new snapshot without tweak")
                    return
                }
                
                self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): [Snapshot] oldSnapshot: \(oldSnapshot.itemIdentifiers.debugDescription)")
                self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): [Snapshot] newSnapshot: \(newSnapshot.itemIdentifiers.debugDescription)")
                await self.updateSnapshotUsingReloadData(
                    tableView: tableView,
                    oldSnapshot: oldSnapshot,
                    newSnapshot: newSnapshot,
                    difference: difference
                )
            }   // end Task
        }
        .store(in: &disposeBag)

        
//        Publishers.CombineLatest3(
//            rootItem.removeDuplicates(),
//            ancestorItems.removeDuplicates(),
//            descendantItems.removeDuplicates()
//        )
//        .receive(on: RunLoop.main)
//        .sink { [weak self] rootItem, ancestorItems, descendantItems in
//            guard let self = self else { return }
//            var items: [Item] = []
//            rootItem.flatMap { items.append($0) }
//            items.append(contentsOf: ancestorItems)
//            items.append(contentsOf: descendantItems)
//            self.updateDeletedStatus(for: items)
//        }
//        .store(in: &disposeBag)
//        
//        Publishers.CombineLatest4(
//            rootItem,
//            ancestorItems,
//            descendantItems,
//            existStatusFetchedResultsController.objectIDs
//        )
//        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)       // some magic to avoid jitter
//        .sink { [weak self] rootItem, ancestorItems, descendantItems, existObjectIDs in
//            guard let self = self else { return }
//            guard let tableView = self.tableView,
//                  let navigationBar = self.contentOffsetAdjustableTimelineViewControllerDelegate?.navigationBar()
//            else { return }
//            
//            guard let diffableDataSource = self.diffableDataSource else { return }
//            let oldSnapshot = diffableDataSource.snapshot()
//            
//            var newSnapshot = NSDiffableDataSourceSnapshot<StatusSection, Item>()
//            newSnapshot.appendSections([.main])
//            
//            let currentState = self.loadThreadStateMachine.currentState
//            
//            // reply to
//            if self.rootNode.value?.replyToID != nil, !(currentState is LoadThreadState.NoMore) {
//                newSnapshot.appendItems([.topLoader], toSection: .main)
//            }
//            
//            let ancestorItems = ancestorItems.filter { item in
//                guard case let .reply(statusObjectID, _) = item else { return false }
//                return existObjectIDs.contains(statusObjectID)
//            }
//            newSnapshot.appendItems(ancestorItems, toSection: .main)
//            
//            // root
//            if let rootItem = rootItem,
//               case let .root(objectID, _) = rootItem,
//               existObjectIDs.contains(objectID) {
//                newSnapshot.appendItems([rootItem], toSection: .main)
//            }
//            
//            // leaf
//            if !(currentState is LoadThreadState.NoMore) {
//                newSnapshot.appendItems([.bottomLoader], toSection: .main)
//            }
//            
//            let descendantItems = descendantItems.filter { item in
//                switch item {
//                case .leaf(let statusObjectID, _):
//                    return existObjectIDs.contains(statusObjectID)
//                default:
//                    return true
//                }
//            }
//            newSnapshot.appendItems(descendantItems, toSection: .main)
//            
//            // difference for first visible item exclude .topLoader
//            guard let difference = self.calculateReloadSnapshotDifference(navigationBar: navigationBar, tableView: tableView, oldSnapshot: oldSnapshot, newSnapshot: newSnapshot) else {
//                diffableDataSource.apply(newSnapshot)
//                return
//            }
//
//            // additional margin for .topLoader
//            let oldTopMargin: CGFloat = {
//                let marginHeight = TimelineTopLoaderTableViewCell.cellHeight
//                if oldSnapshot.itemIdentifiers.contains(.topLoader) {
//                    return marginHeight
//                }
//                if !ancestorItems.isEmpty {
//                    return marginHeight
//                }
//                
//                return .zero
//            }()
//            
//            let oldRootCell: UITableViewCell? = {
//                guard let rootItem = rootItem else { return nil }
//                guard let index = oldSnapshot.indexOfItem(rootItem) else { return nil }
//                guard let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) else { return nil }
//                return cell
//            }()
//            // save height before cell reuse
//            let oldRootCellHeight = oldRootCell?.frame.height
//            
//            diffableDataSource.reloadData(snapshot: newSnapshot) {
//                guard let _ = rootItem else {
//                    return
//                }
//                if let oldRootCellHeight = oldRootCellHeight {
//                    // set bottom inset. Make root item pin to top (with margin).
//                    let bottomSpacing = tableView.safeAreaLayoutGuide.layoutFrame.height - oldRootCellHeight - oldTopMargin
//                    tableView.contentInset.bottom = max(0, bottomSpacing)
//                }
//
//                // set scroll position
//                tableView.scrollToRow(at: difference.targetIndexPath, at: .top, animated: false)
//                let contentOffsetY: CGFloat = {
//                    var offset: CGFloat = tableView.contentOffset.y - difference.offset
//                    if tableView.contentInset.bottom != 0.0 && descendantItems.isEmpty {
//                        // needs restore top margin if bottom inset adjusted AND no descendantItems
//                        offset += oldTopMargin
//                    }
//                    return offset
//                }()
//                tableView.setContentOffset(CGPoint(x: 0, y: contentOffsetY), animated: false)
//            }
//        }
//        .store(in: &disposeBag)
    }
    
}


extension ThreadViewModel {
    
    @MainActor func updateDataSource(
        snapshot: NSDiffableDataSourceSnapshot<StatusSection, StatusItem>,
        animatingDifferences: Bool
    ) async {
        diffableDataSource?.apply(snapshot, animatingDifferences: animatingDifferences)
    }
    
    @MainActor func updateSnapshotUsingReloadData(
        snapshot: NSDiffableDataSourceSnapshot<StatusSection, StatusItem>
    ) async {
        if #available(iOS 15.0, *) {
            await self.diffableDataSource?.applySnapshotUsingReloadData(snapshot)
        } else {
            diffableDataSource?.applySnapshot(snapshot, animated: false, completion: nil)
        }
    }
    
    // Some UI tweaks to present replies and conversation smoothly
    @MainActor private func updateSnapshotUsingReloadData(
        tableView: UITableView,
        oldSnapshot: NSDiffableDataSourceSnapshot<StatusSection, StatusItem>,
        newSnapshot: NSDiffableDataSourceSnapshot<StatusSection, StatusItem>,
        difference: ThreadViewModel.Difference // <StatusItem>
    ) async {
        let replies: [StatusItem] = {
            newSnapshot.itemIdentifiers.filter { item in
                guard case let .thread(thread) = item else { return false }
                guard case .reply = thread else { return false }
                return true
            }
        }()
        // additional margin for .topLoader
        let oldTopMargin: CGFloat = {
            let marginHeight = TimelineTopLoaderTableViewCell.cellHeight
            if oldSnapshot.itemIdentifiers.contains(.topLoader) || !replies.isEmpty {
                return marginHeight
            }
            return .zero
        }()
        
        await self.updateSnapshotUsingReloadData(snapshot: newSnapshot)

        // note:
        // tweak the content offset and bottom inset
        // make the table view stable when data reload
        // the keypoint is set the bottom inset to make the root padding with "TopLoaderHeight" to top edge
        // and restore the "TopLoaderHeight" when bottom inset adjusted
        
        // set bottom inset. Make root item pin to top.
        if let item = root.flatMap({ StatusItem.thread($0) }),
           let index = newSnapshot.indexOfItem(item),
           let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0))
        {
            // always set bottom inset due to lazy reply loading
            // otherwise tableView will jump when insert replies
            let bottomSpacing = tableView.safeAreaLayoutGuide.layoutFrame.height - cell.frame.height - oldTopMargin
            let additionalInset = round(tableView.contentSize.height - cell.frame.maxY)
            
            tableView.contentInset.bottom = max(0, bottomSpacing - additionalInset)
            self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): content inset bottom: \(tableView.contentInset.bottom)")
        }

        // set scroll position
        tableView.scrollToRow(at: difference.targetIndexPath, at: .top, animated: false)
        tableView.contentOffset.y = {
            var offset: CGFloat = tableView.contentOffset.y - difference.sourceDistanceToTableViewTopEdge
            if tableView.contentInset.bottom != 0.0 {
                // needs restore top margin if bottom inset adjusted
                offset += oldTopMargin
            }
            return offset
        }()
        self.logger.log(level: .debug, "\((#file as NSString).lastPathComponent, privacy: .public)[\(#line, privacy: .public)], \(#function, privacy: .public): applied new snapshot")
    }
}

extension ThreadViewModel {
    struct Difference {
        let item: StatusItem
        let sourceIndexPath: IndexPath
        let sourceDistanceToTableViewTopEdge: CGFloat
        let targetIndexPath: IndexPath
    }

    @MainActor private func calculateReloadSnapshotDifference(
        tableView: UITableView,
        oldSnapshot: NSDiffableDataSourceSnapshot<StatusSection, StatusItem>,
        newSnapshot: NSDiffableDataSourceSnapshot<StatusSection, StatusItem>
    ) -> Difference? {
        guard oldSnapshot.numberOfItems != 0 else { return nil }
        guard let indexPathsForVisibleRows = tableView.indexPathsForVisibleRows?.sorted() else { return nil }

        // find index of the first visible item in both old and new snapshot
        var _index: Int?
        let items = oldSnapshot.itemIdentifiers(inSection: .main)
        for (i, item) in items.enumerated() {
            guard let indexPath = indexPathsForVisibleRows.first(where: { $0.row == i }) else { continue }
            guard newSnapshot.indexOfItem(item) != nil else { continue }
            let rectForCell = tableView.rectForRow(at: indexPath)
            let distanceToTableViewTopEdge = tableView.convert(rectForCell, to: nil).origin.y - tableView.safeAreaInsets.top
            guard distanceToTableViewTopEdge >= 0 else { continue }
            _index = i
            break
        }

        guard let index = _index else { return nil }
        let sourceIndexPath = IndexPath(row: index, section: 0)

        let rectForSourceItemCell = tableView.rectForRow(at: sourceIndexPath)
        let sourceDistanceToTableViewTopEdge = tableView.convert(rectForSourceItemCell, to: nil).origin.y - tableView.safeAreaInsets.top

        guard sourceIndexPath.section < oldSnapshot.numberOfSections,
              sourceIndexPath.row < oldSnapshot.numberOfItems(inSection: oldSnapshot.sectionIdentifiers[sourceIndexPath.section])
        else { return nil }

        let sectionIdentifier = oldSnapshot.sectionIdentifiers[sourceIndexPath.section]
        let item = oldSnapshot.itemIdentifiers(inSection: sectionIdentifier)[sourceIndexPath.row]

        guard let targetIndexPathRow = newSnapshot.indexOfItem(item),
              let newSectionIdentifier = newSnapshot.sectionIdentifier(containingItem: item),
              let targetIndexPathSection = newSnapshot.indexOfSection(newSectionIdentifier)
        else { return nil }

        let targetIndexPath = IndexPath(row: targetIndexPathRow, section: targetIndexPathSection)

        return Difference(
            item: item,
            sourceIndexPath: sourceIndexPath,
            sourceDistanceToTableViewTopEdge: sourceDistanceToTableViewTopEdge,
            targetIndexPath: targetIndexPath
        )
    }
}

//extension ThreadViewModel {
//    private func updateDeletedStatus(for items: [Item]) {
//        let parentManagedObjectContext = context.managedObjectContext
//        let managedObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
//        managedObjectContext.parent = parentManagedObjectContext
//        managedObjectContext.perform {
//            var statusIDs: [Status.ID] = []
//            for item in items {
//                switch item {
//                case .root(let objectID, _):
//                    guard let status = managedObjectContext.object(with: objectID) as? Status else { continue }
//                    statusIDs.append(status.id)
//                case .reply(let objectID, _):
//                    guard let status = managedObjectContext.object(with: objectID) as? Status else { continue }
//                    statusIDs.append(status.id)
//                case .leaf(let objectID, _):
//                    guard let status = managedObjectContext.object(with: objectID) as? Status else { continue }
//                    statusIDs.append(status.id)
//                default:
//                    continue
//                }
//            }
//            DispatchQueue.main.async { [weak self] in
//                guard let self = self else { return }
//                self.existStatusFetchedResultsController.statusIDs.value = statusIDs
//            }
//        }
//    }
//}
