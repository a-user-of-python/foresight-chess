// ChessGame.swift
// Adaptive Chess — complete chess engine: game state, legal move generation,
// make/undo, and all terminal-condition detection.
//
// Design notes:
// - Board is an 8x8 array: board[rank][file], rank 0 = White's back rank.
// - Move generation is pseudo-legal first, then each candidate is applied with
//   makeMove and kept only if the mover's own king is not left in check.
//   This single mechanism correctly handles pins, discovered checks, double
//   checks, en passant pins, and castling through check — no special cases.
// - makeMove/undoMove are perfectly reversible via an UndoInfo stack, so the
//   AI can search with them freely.
// - Threefold repetition uses an incrementally maintained position-count map.
// - Callers MUST pass moves obtained from legalMoves() into makeMove(_:).

import Foundation

// MARK: - Castling rights

/// Which castles are still available. Any king move, or rook move/capture
/// involving its original square, clears the corresponding right.
struct CastlingRights: Equatable {
    var whiteKingside = false
    var whiteQueenside = false
    var blackKingside = false
    var blackQueenside = false

    var fenString: String {
        var s = ""
        if whiteKingside  { s += "K" }
        if whiteQueenside { s += "Q" }
        if blackKingside  { s += "k" }
        if blackQueenside { s += "q" }
        return s.isEmpty ? "-" : s
    }
}

// MARK: - ChessGame

public class ChessGame {

    // MARK: State

    /// board[rank][file]; rank 0 is White's 1st rank. nil = empty square.
    private var board: [[Piece?]]
    public private(set) var sideToMove: PieceColor
    private var castling: CastlingRights
    /// Square a pawn could capture en passant to (set only on a double push).
    private var enPassantTarget: Square?
    /// Half-moves since the last pawn move or capture (50-move rule).
    private var halfmoveClock: Int
    private var fullmoveNumber: Int

    // MARK: - Neural network inputs (read-only snapshots of game state)

    public var whiteCanCastleKingside: Bool { castling.whiteKingside }
    public var whiteCanCastleQueenside: Bool { castling.whiteQueenside }
    public var blackCanCastleKingside: Bool { castling.blackKingside }
    public var blackCanCastleQueenside: Bool { castling.blackQueenside }
    public var enPassantFile: Int? { enPassantTarget?.file }
    public var halfmovesSincePawnOrCapture: Int { halfmoveClock }

    /// Attack map for the neural network: which squares each side attacks.
    /// This is the "why" — the network doesn't just see where pieces are,
    /// it sees what they threaten.
    public func isSquareAttacked(_ sq: Square, by attacker: PieceColor) -> Bool {
        isAttacked(sq, by: attacker)
    }

    /// Everything needed to perfectly reverse one makeMove.
    private struct UndoInfo {
        let move: Move
        let captured: Piece?
        /// Square the captured piece came from (== move.to, except en passant).
        let capturedSquare: Square?
        let prevCastling: CastlingRights
        let prevEnPassant: Square?
        let prevHalfmove: Int
        let prevFullmove: Int
    }

    private var history: [UndoInfo] = []
    /// How many times each position (pieces + side + castling + ep) has occurred.
    private var positionCounts: [String: Int] = [:]

    // MARK: - Initializers

    /// Standard starting position.
    public init() {
        // The literal below is valid by construction; force-unwrap is safe.
        let g = ChessGame(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")!
        self.board = g.board
        self.sideToMove = g.sideToMove
        self.castling = g.castling
        self.enPassantTarget = g.enPassantTarget
        self.halfmoveClock = g.halfmoveClock
        self.fullmoveNumber = g.fullmoveNumber
        self.history = []
        self.positionCounts = g.positionCounts
    }

    /// Failable FEN initializer (for tests / setup positions).
    /// Returns nil when the FEN string is malformed.
    public init?(fen: String) {
        let parts = fen.split(separator: " ")
        guard parts.count >= 4 else { return nil }

        // 1. Piece placement (rank 8 first).
        var b: [[Piece?]] = Array(repeating: Array(repeating: nil, count: 8), count: 8)
        let rows = parts[0].split(separator: "/")
        guard rows.count == 8 else { return nil }
        for (i, row) in rows.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in row {
                if let digit = ch.wholeNumberValue {
                    file += digit
                } else if let type = PieceType.fromFENLetter(ch) {
                    guard file < 8 else { return nil }
                    let color: PieceColor = ch.isUppercase ? .white : .black
                    b[rank][file] = Piece(type: type, color: color)
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }

        // 2. Side to move.
        let side: PieceColor
        if parts[1] == "w" { side = .white }
        else if parts[1] == "b" { side = .black }
        else { return nil }

        // 3. Castling rights.
        var c = CastlingRights()
        let castlePart = String(parts[2])
        if castlePart != "-" {
            for ch in castlePart {
                switch ch {
                case "K": c.whiteKingside = true
                case "Q": c.whiteQueenside = true
                case "k": c.blackKingside = true
                case "q": c.blackQueenside = true
                default: return nil
                }
            }
        }

        // 4. En passant target.
        var ep: Square? = nil
        let epPart = String(parts[3])
        if epPart != "-" {
            guard let sq = Square(algebraic: epPart) else { return nil }
            ep = sq
        }

        // 5-6. Halfmove clock and fullmove number.
        var half = 0, full = 1
        if parts.count >= 5 { guard let h = Int(parts[4]) else { return nil }; half = h }
        if parts.count >= 6 { guard let f = Int(parts[5]) else { return nil }; full = f }

        self.board = b
        self.sideToMove = side
        self.castling = c
        self.enPassantTarget = ep
        self.halfmoveClock = half
        self.fullmoveNumber = full
        self.history = []
        self.positionCounts = [:]
        // Record the initial position for repetition tracking.
        let key = positionKey()
        self.positionCounts[key] = 1
    }

    // MARK: - Basic accessors

    /// The piece on a square, or nil when empty (or off-board).
    public func piece(at square: Square) -> Piece? {
        guard square.isValid else { return nil }
        return board[square.rank][square.file]
    }

    /// Moves played so far, oldest first. Used by the game recorder.
    public var moveHistory: [Move] {
        history.map { $0.move }
    }

    // MARK: - Attack detection

    private static let knightOffsets = [(1, 2), (2, 1), (2, -1), (1, -2),
                                        (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingOffsets = [(1, 0), (1, 1), (0, 1), (-1, 1),
                                      (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let rookDirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let bishopDirs = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    /// True when `sq` is attacked by any piece of color `attacker`.
    private func isAttacked(_ sq: Square, by attacker: PieceColor) -> Bool {
        // Pawn attacks. A white pawn attacks from one rank below its target.
        let pawnRank = sq.rank + (attacker == .white ? -1 : 1)
        for df in [-1, 1] {
            let f = sq.file + df
            if Square.isValid(file: f, rank: pawnRank),
               let p = board[pawnRank][f],
               p.color == attacker, p.type == .pawn {
                return true
            }
        }
        // Knight attacks.
        for (df, dr) in ChessGame.knightOffsets {
            if let t = sq.offsetBy(file: df, rank: dr),
               let p = board[t.rank][t.file],
               p.color == attacker, p.type == .knight {
                return true
            }
        }
        // King attacks.
        for (df, dr) in ChessGame.kingOffsets {
            if let t = sq.offsetBy(file: df, rank: dr),
               let p = board[t.rank][t.file],
               p.color == attacker, p.type == .king {
                return true
            }
        }
        // Sliding pieces: orthogonal rays see rooks/queens.
        for (df, dr) in ChessGame.rookDirs {
            var t = sq.offsetBy(file: df, rank: dr)
            while let cur = t {
                if let p = board[cur.rank][cur.file] {
                    if p.color == attacker && (p.type == .rook || p.type == .queen) {
                        return true
                    }
                    break
                }
                t = cur.offsetBy(file: df, rank: dr)
            }
        }
        // Sliding pieces: diagonal rays see bishops/queens.
        for (df, dr) in ChessGame.bishopDirs {
            var t = sq.offsetBy(file: df, rank: dr)
            while let cur = t {
                if let p = board[cur.rank][cur.file] {
                    if p.color == attacker && (p.type == .bishop || p.type == .queen) {
                        return true
                    }
                    break
                }
                t = cur.offsetBy(file: df, rank: dr)
            }
        }
        return false
    }

    /// True when `color`'s king is under attack.
    public func isInCheck(_ color: PieceColor) -> Bool {
        for rank in 0..<8 {
            for file in 0..<8 {
                if let p = board[rank][file], p.type == .king, p.color == color {
                    return isAttacked(Square(file: file, rank: rank), by: color.opposite)
                }
            }
        }
        return false // No king on board (shouldn't happen); treat as safe.
    }

    // MARK: - Move generation

    /// ALL legal moves for the side to move. Never contains an illegal move.
    public func legalMoves() -> [Move] {
        var pseudo: [Move] = []
        pseudo.reserveCapacity(40)
        let us = sideToMove
        for rank in 0..<8 {
            for file in 0..<8 {
                guard let piece = board[rank][file], piece.color == us else { continue }
                appendPseudoMoves(for: piece, from: Square(file: file, rank: rank), into: &pseudo)
            }
        }
        // Legality filter: a move is legal iff it doesn't leave our own king
        // in check. Applying + reverting each candidate handles pins,
        // discovered checks, en passant pins, and castling rules uniformly.
        var legal: [Move] = []
        legal.reserveCapacity(pseudo.count)
        for m in pseudo {
            makeMove(m)
            if !isInCheck(us) {
                legal.append(m)
            }
            undoMove()
        }
        return legal
    }

    /// Legal moves starting from a specific square (for tap-to-move UI).
    public func legalMoves(from square: Square) -> [Move] {
        legalMoves().filter { $0.from == square }
    }

    /// Pseudo-legal moves for one piece (may leave own king in check;
    /// the caller filters). Castling moves are included only when all
    /// positional conditions hold (rights, empty squares, unattacked path).
    private func appendPseudoMoves(for piece: Piece, from: Square, into moves: inout [Move]) {
        switch piece.type {
        case .pawn:
            appendPawnMoves(piece: piece, from: from, into: &moves)
        case .knight:
            for (df, dr) in ChessGame.knightOffsets {
                appendStepMove(piece: piece, from: from, to: from.offsetBy(file: df, rank: dr), into: &moves)
            }
        case .bishop:
            appendSliderMoves(piece: piece, from: from, dirs: ChessGame.bishopDirs, into: &moves)
        case .rook:
            appendSliderMoves(piece: piece, from: from, dirs: ChessGame.rookDirs, into: &moves)
        case .queen:
            appendSliderMoves(piece: piece, from: from,
                              dirs: ChessGame.rookDirs + ChessGame.bishopDirs, into: &moves)
        case .king:
            for (df, dr) in ChessGame.kingOffsets {
                appendStepMove(piece: piece, from: from, to: from.offsetBy(file: df, rank: dr), into: &moves)
            }
            appendCastleMoves(piece: piece, from: from, into: &moves)
        }
    }

    /// Single-step move (knight/king/pawn captures): destination must be
    /// on-board and not occupied by a friendly piece.
    private func appendStepMove(piece: Piece, from: Square, to: Square?, into moves: inout [Move]) {
        guard let to = to else { return }
        if let target = board[to.rank][to.file] {
            if target.color != piece.color {
                moves.append(Move(from: from, to: to, isCapture: true))
            }
        } else {
            moves.append(Move(from: from, to: to))
        }
    }

    /// Sliding moves (bishop/rook/queen): walk each ray until blocked.
    private func appendSliderMoves(piece: Piece, from: Square,
                                   dirs: [(Int, Int)], into moves: inout [Move]) {
        for (df, dr) in dirs {
            var t = from.offsetBy(file: df, rank: dr)
            while let cur = t {
                if let target = board[cur.rank][cur.file] {
                    if target.color != piece.color {
                        moves.append(Move(from: from, to: cur, isCapture: true))
                    }
                    break
                }
                moves.append(Move(from: from, to: cur))
                t = cur.offsetBy(file: df, rank: dr)
            }
        }
    }

    /// All pawn moves: pushes, double pushes, captures, en passant, promotions.
    private func appendPawnMoves(piece: Piece, from: Square, into moves: inout [Move]) {
        let forward = piece.color == .white ? 1 : -1
        let startRank = piece.color == .white ? 1 : 6
        let promoRank = piece.color == .white ? 7 : 0

        // Single push.
        if let one = from.offsetBy(file: 0, rank: forward), board[one.rank][one.file] == nil {
            if one.rank == promoRank {
                appendPromotions(from: from, to: one, isCapture: false, into: &moves)
            } else {
                moves.append(Move(from: from, to: one))
                // Double push from the starting rank (both squares must be empty).
                if from.rank == startRank,
                   let two = from.offsetBy(file: 0, rank: 2 * forward),
                   board[two.rank][two.file] == nil {
                    moves.append(Move(from: from, to: two))
                }
            }
        }
        // Captures (including en passant).
        for df in [-1, 1] {
            guard let to = from.offsetBy(file: df, rank: forward) else { continue }
            if let target = board[to.rank][to.file], target.color != piece.color {
                if to.rank == promoRank {
                    appendPromotions(from: from, to: to, isCapture: true, into: &moves)
                } else {
                    moves.append(Move(from: from, to: to, isCapture: true))
                }
            } else if let ep = enPassantTarget, to == ep {
                // En passant capture: the captured pawn sits beside us.
                moves.append(Move(from: from, to: to, isCapture: true, isEnPassant: true))
            }
        }
    }

    /// Expand one pawn move into the four promotion options.
    private func appendPromotions(from: Square, to: Square, isCapture: Bool, into moves: inout [Move]) {
        for pt in [PieceType.queen, .rook, .bishop, .knight] as [PieceType] {
            moves.append(Move(from: from, to: to, promotion: pt, isCapture: isCapture))
        }
    }

    /// Castling moves. All FIDE conditions are enforced here:
    /// rights intact, king not in check, squares between empty, and every
    /// square the king crosses (including destination) unattacked.
    private func appendCastleMoves(piece: Piece, from: Square, into moves: inout [Move]) {
        let homeRank = piece.color == .white ? 0 : 7
        guard from == Square(file: 4, rank: homeRank) else { return }
        let enemy = piece.color.opposite
        let e = Square(file: 4, rank: homeRank)

        let kingsideRight = piece.color == .white ? castling.whiteKingside : castling.blackKingside
        if kingsideRight
            && board[homeRank][5] == nil && board[homeRank][6] == nil
            && !isAttacked(e, by: enemy)
            && !isAttacked(Square(file: 5, rank: homeRank), by: enemy)
            && !isAttacked(Square(file: 6, rank: homeRank), by: enemy) {
            moves.append(Move(from: from, to: Square(file: 6, rank: homeRank),
                              isCastleKingside: true))
        }

        let queensideRight = piece.color == .white ? castling.whiteQueenside : castling.blackQueenside
        if queensideRight
            && board[homeRank][1] == nil && board[homeRank][2] == nil && board[homeRank][3] == nil
            && !isAttacked(e, by: enemy)
            && !isAttacked(Square(file: 3, rank: homeRank), by: enemy)
            && !isAttacked(Square(file: 2, rank: homeRank), by: enemy) {
            moves.append(Move(from: from, to: Square(file: 2, rank: homeRank),
                              isCastleQueenside: true))
        }
    }

    // MARK: - makeMove / undoMove

    /// Apply a move from `legalMoves()`. Perfectly reversible via `undoMove()`.
    public func makeMove(_ move: Move) {
        let us = sideToMove
        let from = move.from, to = move.to
        assert(board[from.rank][from.file]?.color == us,
               "makeMove: expected own piece on \(from.algebraic)")

        // Defensive: never crash on a bad move (e.g. a stale move replayed
        // by the game recorder). A no-op is safer than a crash.
        guard let moving = board[from.rank][from.file], moving.color == us else {
            return
        }

        // Snapshot everything that changes, for undo.
        var undo = UndoInfo(move: move, captured: nil, capturedSquare: nil,
                            prevCastling: castling, prevEnPassant: enPassantTarget,
                            prevHalfmove: halfmoveClock, prevFullmove: fullmoveNumber)

        // 1. Remove any captured piece. En passant captures the pawn beside us.
        if move.isEnPassant {
            let capSq = Square(file: to.file, rank: from.rank)
            undo = UndoInfo(move: move, captured: board[capSq.rank][capSq.file],
                            capturedSquare: capSq, prevCastling: undo.prevCastling,
                            prevEnPassant: undo.prevEnPassant, prevHalfmove: undo.prevHalfmove,
                            prevFullmove: undo.prevFullmove)
            board[capSq.rank][capSq.file] = nil
        } else if let target = board[to.rank][to.file] {
            undo = UndoInfo(move: move, captured: target, capturedSquare: to,
                            prevCastling: undo.prevCastling, prevEnPassant: undo.prevEnPassant,
                            prevHalfmove: undo.prevHalfmove, prevFullmove: undo.prevFullmove)
        }

        // 2. Move the piece (promoting if needed).
        board[from.rank][from.file] = nil
        if let promo = move.promotion {
            board[to.rank][to.file] = Piece(type: promo, color: us)
        } else {
            board[to.rank][to.file] = moving
        }

        // 3. Castling also moves the rook.
        if move.isCastleKingside {
            board[from.rank][5] = board[from.rank][7]
            board[from.rank][7] = nil
        } else if move.isCastleQueenside {
            board[from.rank][3] = board[from.rank][0]
            board[from.rank][0] = nil
        }

        // 4. Update castling rights: king move clears both; rook leaving or
        //    being captured on its home square clears that side's right.
        if moving.type == .king {
            if us == .white { castling.whiteKingside = false; castling.whiteQueenside = false }
            else            { castling.blackKingside = false; castling.blackQueenside = false }
        }
        clearRookRight(forSquare: from)
        if let cs = undo.capturedSquare, undo.captured?.type == .rook {
            clearRookRight(forSquare: cs)
        }

        // 5. En passant target: set only on a pawn double push.
        if moving.type == .pawn && abs(to.rank - from.rank) == 2 {
            enPassantTarget = Square(file: from.file, rank: (from.rank + to.rank) / 2)
        } else {
            enPassantTarget = nil
        }

        // 6. Halfmove clock resets on pawn moves and captures.
        if moving.type == .pawn || undo.captured != nil {
            halfmoveClock = 0
        } else {
            halfmoveClock += 1
        }

        // 7. Flip the side to move; bump the fullmove number after Black.
        sideToMove = us.opposite
        if us == .black { fullmoveNumber += 1 }

        // 8. Track the new position for threefold repetition.
        history.append(undo)
        let key = positionKey()
        positionCounts[key, default: 0] += 1
    }

    /// Clear the castling right tied to a rook's home square, if `sq` is one.
    private func clearRookRight(forSquare sq: Square) {
        switch (sq.file, sq.rank) {
        case (0, 0): castling.whiteQueenside = false
        case (7, 0): castling.whiteKingside = false
        case (0, 7): castling.blackQueenside = false
        case (7, 7): castling.blackKingside = false
        default: break
        }
    }

    /// Perfectly reverse the last `makeMove`. No-op when no moves were made.
    public func undoMove() {
        guard let undo = history.popLast() else { return }

        // Un-count the position we're leaving.
        let key = positionKey()
        if let c = positionCounts[key] {
            positionCounts[key] = c - 1
        }

        let move = undo.move
        let us = sideToMove.opposite // the side that made the move
        let from = move.from, to = move.to

        // Restore clocks, rights, en passant, and side to move.
        sideToMove = us
        castling = undo.prevCastling
        enPassantTarget = undo.prevEnPassant
        halfmoveClock = undo.prevHalfmove
        fullmoveNumber = undo.prevFullmove

        // Move the rook back (castling).
        if move.isCastleKingside {
            board[from.rank][7] = board[from.rank][5]
            board[from.rank][5] = nil
        } else if move.isCastleQueenside {
            board[from.rank][0] = board[from.rank][3]
            board[from.rank][3] = nil
        }

        // Move the piece back (a promotion reverts to a pawn).
        let movedType: PieceType = move.promotion != nil ? .pawn : board[to.rank][to.file]!.type
        board[to.rank][to.file] = nil
        board[from.rank][from.file] = Piece(type: movedType, color: us)

        // Restore any captured piece (en passant: beside the pawn's origin).
        if let cap = undo.captured, let cs = undo.capturedSquare {
            board[cs.rank][cs.file] = cap
        }
    }

    // MARK: - Position key (repetition)

    /// Compact key: 64 piece chars + side + castling + en passant square.
    private func positionKey() -> String {
        var s = ""
        s.reserveCapacity(80)
        for rank in 0..<8 {
            for file in 0..<8 {
                if let p = board[rank][file] {
                    s.append(p.fenChar)
                } else {
                    s.append(".")
                }
            }
        }
        s += sideToMove == .white ? "w" : "b"
        s += castling.fenString
        s += enPassantTarget?.algebraic ?? "-"
        return s
    }

    // MARK: - Terminal conditions

    /// Side to move is in check and has no legal moves.
    public var isCheckmate: Bool {
        isInCheck(sideToMove) && legalMoves().isEmpty
    }

    /// Side to move is NOT in check and has no legal moves.
    public var isStalemate: Bool {
        !isInCheck(sideToMove) && legalMoves().isEmpty
    }

    /// 50 full moves (100 half-moves) without a pawn move or capture.
    public var isDrawByFiftyMove: Bool {
        halfmoveClock >= 100
    }

    /// The current position has occurred three times.
    public var isDrawByRepetition: Bool {
        (positionCounts[positionKey()] ?? 0) >= 3
    }

    /// K vs K; K+minor vs K; K+B vs K+B with bishops on the same color.
    public var isDrawByInsufficientMaterial: Bool {
        var minors: [(type: PieceType, square: Square)] = []
        for rank in 0..<8 {
            for file in 0..<8 {
                guard let p = board[rank][file], p.type != .king else { continue }
                // Any pawn/rook/queen can force mate.
                if p.type == .pawn || p.type == .rook || p.type == .queen {
                    return false
                }
                minors.append((p.type, Square(file: file, rank: rank)))
            }
        }
        if minors.isEmpty { return true } // K vs K
        if minors.count == 1 { return true } // K+B vs K, K+N vs K
        if minors.count == 2 && minors.allSatisfy({ $0.type == .bishop }) {
            // K+B vs K+B: draw only when both bishops share a square color.
            let c0 = (minors[0].square.file + minors[0].square.rank) % 2
            let c1 = (minors[1].square.file + minors[1].square.rank) % 2
            return c0 == c1
        }
        return false // K+N vs K+N, K+B vs K+N, etc. can still mate.
    }

    /// True when the game has ended by any rule.
    public var isGameOver: Bool {
        isCheckmate || isStalemate || isDrawByFiftyMove
            || isDrawByRepetition || isDrawByInsufficientMaterial
    }

    /// The game result, or nil while the game is still in progress.
    public var result: GameResult? {
        if isCheckmate {
            return sideToMove == .white ? .blackWins : .whiteWins
        }
        if isStalemate || isDrawByFiftyMove || isDrawByRepetition || isDrawByInsufficientMaterial {
            return .draw
        }
        return nil
    }

    // MARK: - FEN

    /// Standard FEN string for the current position (for tests / debugging).
    public func toFEN() -> String {
        var rows: [String] = []
        for rank in (0..<8).reversed() {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let p = board[rank][file] {
                    if empty > 0 { row += "\(empty)"; empty = 0 }
                    row.append(p.fenChar)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += "\(empty)" }
            rows.append(row)
        }
        let side = sideToMove == .white ? "w" : "b"
        let ep = enPassantTarget?.algebraic ?? "-"
        return "\(rows.joined(separator: "/")) \(side) \(castling.fenString) \(ep) \(halfmoveClock) \(fullmoveNumber)"
    }
}
