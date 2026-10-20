import Foundation

/// Only oversized blocks repeat across ranges; their slices advance by `offset`.
enum ReportPDFLayout {
    struct Page: Equatable {
        let blocks: Range<Int>
        let offset: CGFloat
    }

    static func pages(blockHeights: [CGFloat], contentHeight: CGFloat, firstPageContentHeight: CGFloat? = nil) -> [Page] {
        precondition(contentHeight.isFinite && contentHeight > 0)
        let firstHeight = firstPageContentHeight ?? contentHeight
        precondition(firstHeight.isFinite && firstHeight > 0)
        precondition(blockHeights.allSatisfy { $0.isFinite && $0 >= 0 })
        var pages: [Page] = []
        var start = 0
        var used: CGFloat = 0
        var capacity: CGFloat { pages.isEmpty ? firstHeight : contentHeight }

        for (index, height) in blockHeights.enumerated() {
            if used + height > capacity, start < index {
                pages.append(Page(blocks: start..<index, offset: 0))
                start = index
                used = 0
            }
            if height > capacity {
                var offset: CGFloat = 0
                while offset < height {
                    let sliceHeight = capacity
                    pages.append(Page(blocks: index..<(index + 1), offset: offset))
                    offset += sliceHeight
                }
                start = index + 1
                used = 0
            } else {
                used += height
            }
        }
        if start < blockHeights.count {
            pages.append(Page(blocks: start..<blockHeights.count, offset: 0))
        }
        return pages.isEmpty ? [Page(blocks: 0..<0, offset: 0)] : pages
    }
}
