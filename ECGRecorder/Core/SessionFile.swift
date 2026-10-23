import CoreTransferable
import UniformTypeIdentifiers

/// The session CSV shared as-is; the share sheet reads the file in place.
struct SessionFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { SentTransferredFile($0.url) }
    }
}
