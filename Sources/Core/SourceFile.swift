
import Foundation

var currentDirectory = FileManager.default.currentDirectoryPath
let fileExtension = ".cte"
var buildDirectory = currentDirectory + "/" + fileExtension + "/"

var moduleName: String!

var knownSourceFiles: [String: SourceFile] = [:]

var currentFilenoMutex = Mutex()
var currentFileno: UInt32 = 1

// sourcery:noinit
public final class SourceFile {

    weak var firstImportedFrom: SourceFile?
    var isInitialFile: Bool {
        return firstImportedFrom == nil
    }

    /// The base offset for this file
    var fileno: UInt32
    var size: UInt32
    var lineOffsets: [UInt32] = [0]
    var linesOfSource: Int = 0

    var errors: [SourceError] = []
    var notes: [Int: [String]] = [:]

    var nodes: [Node] = []

    var handle: FileHandle
    var fullpath: String

    var stage: String = ""
    var hasBeenParsed: Bool = false
    var hasBeenChecked: Bool = false
    var hasBeenGenerated: Bool = false

    var pathFirstImportedAs: String
    var imports: [Import] = []

    // Set in Checker
    var scope: Scope!
    var linkedLibraries: Set<String> = []

    init(handle: FileHandle, fullpath: String, pathImportedAs: String, importedFrom: SourceFile?) {
        self.handle = handle
        self.fullpath = fullpath
        self.pathFirstImportedAs = pathImportedAs
        self.firstImportedFrom = importedFrom
        self.size = UInt32(handle.seekToEndOfFile())
        currentFilenoMutex.lock()
        self.fileno = currentFileno
        currentFileno += 1
        currentFilenoMutex.unlock()
        handle.seek(toFileOffset: 0)
    }

    /// - Returns: nil iff the file could not be located or opened for reading
    public static func new(path: String, importedFrom: SourceFile? = nil) -> SourceFile? {

        var pathRelativeToInitialFile = path

        if let importedFrom = importedFrom {
            pathRelativeToInitialFile = dirname(path: importedFrom.fullpath) + path
        }

        guard let fullpath = realpath(relpath: pathRelativeToInitialFile) else {
            return nil
        }

        if let existing = knownSourceFiles[fullpath] {
            return existing
        }

        guard let handle = FileHandle(forReadingAtPath: fullpath) else {
            return nil
        }

        let sourceFile = SourceFile(handle: handle, fullpath: fullpath, pathImportedAs: path, importedFrom: importedFrom)
        knownSourceFiles[fullpath] = sourceFile

        return sourceFile
    }
}

extension SourceFile {

    func add(import i: Import, importedFrom: SourceFile? = nil) -> SourceFile? {

        switch i.path {
        case let path as BasicLit where path.token == .string:
            guard let file = SourceFile.new(path: path.text, importedFrom: importedFrom) else {
                addError("Failed to open '\(path.text)'", path.start)
                return nil
            }
            let parsingJob = Job("\(path.text) - Parsing", work: file.parseEmittingErrors)
            let checkingJob = Job("\(path.text) - Checking", work: file.checkEmittingErrors)
            parsingJob.addDependent(checkingJob)
            threadPool.add(job: parsingJob)
            i.resolvedName = pathToEntityName(path.text)
            return file

        case let call as Call where (call.fun as? Ident)?.name == "git":
            print("Found git import, not executing")
            return nil

        default:
            addError("Expected import path as string", i.path.start)
            return nil
        }
    }
}

extension SourceFile {

    public func start() {
        let parsingJob = Job("\(basename(path: pathFirstImportedAs)) - Parsing", work: parseEmittingErrors)
        let checkingJob = Job("\(basename(path: pathFirstImportedAs)) - Checking", work: checkEmittingErrors)
        parsingJob.addDependent(checkingJob)
        threadPool.add(job: parsingJob)
    }

    public func parseEmittingErrors() {
        assert(!hasBeenParsed)
        let startTime = gettime()

        stage = "Parsing"
        var parser = Parser(file: self)
        self.nodes = parser.parseFile()
        let importedFiles = imports.flatMap({ $0.file })
        for importedFile in importedFiles {
            guard !importedFile.hasBeenParsed else {
                continue
            }
            importedFile.parseEmittingErrors()
        }
        hasBeenParsed = true
        emitErrors(for: self, at: stage)

        let endTime = gettime()
        let totalTime = endTime - startTime
        timingMutex.lock()
        parseStageTiming += totalTime
        timingMutex.unlock()
    }

    public func checkEmittingErrors() {
        assert(hasBeenParsed)
        guard !hasBeenChecked else {
            return
        }
        let startTime = gettime()

        stage = "Checking"
        var checker = Checker(file: self)
        checker.check()
        hasBeenChecked = true
        emitErrors(for: self, at: stage)

        let endTime = gettime()
        let totalTime = endTime - startTime
        timingMutex.lock()
        checkStageTiming += totalTime
        timingMutex.unlock()
    }
}

extension SourceFile {
    
    func addLine(offset: UInt32) {
        assert(lineOffsets.count == 0 || lineOffsets.last! < offset)
        lineOffsets.append(offset)
    }

    func pos(offset: UInt32) -> Pos {
        assert(offset <= self.size)
        return Pos(fileno: fileno, offset: offset)
    }

    func offset(pos: Pos) -> UInt32 {
        assert(pos.offset <= size)
        return pos.offset
    }

    func position(for pos: Pos) -> Position {
        return unpack(offset: offset(pos: pos))
    }

    func position(forOffset offset: UInt32) -> Position {
        return unpack(offset: offset)
    }

    func unpack(offset: UInt32) -> Position {
        var line, column: UInt32
        if let firstPast = lineOffsets.enumerated().first(where: { $0.element > offset }) {
            let i = firstPast.offset - 1
            line = UInt32(i) + 1
            column = offset - lineOffsets[i] + 1
        } else {
            (line, column) = (0, 0)
        }
        return Position(filename: pathFirstImportedAs, offset: offset, line: line, column: column)
    }

    func addError(_ msg: String, _ pos: Pos) {
        let error = SourceError(pos: pos, msg: msg)
        errors.append(error)
    }

    func attachNote(_ message: String) {
        assert(!errors.isEmpty)

        guard var existingNotes = notes[errors.endIndex - 1] else {
            notes[errors.endIndex - 1] = [message]
            return
        }
        existingNotes.append(message)
        notes[errors.endIndex - 1] = existingNotes
    }
}
