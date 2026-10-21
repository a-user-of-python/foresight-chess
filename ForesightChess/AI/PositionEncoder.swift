import Foundation
enum PositionEncoder {
    /// Full 911-input encoding — every distinct element of chess state:
    /// 768 piece squares + side to move + 4 castling rights +
    /// 8 en-passant file one-hot + halfmove clock + check flag +
    /// 128 attack map (64 squares × attacked-by-white, 64 × attacked-by-black).
    ///
    /// The attack map is the "why": the network doesn't just see WHERE
    /// pieces are, it sees WHAT THEY THREATEN. A knight on f3 is just a
    /// knight — but a knight on f3 attacking h2 next to an undefended king
    /// is a mating threat. The network can now learn that distinction.
    static func encode(_ game: ChessGame) -> [Float] {
        var x = [Float](repeating: 0, count: KnowledgeNet.inputSize)
        for rank in 0..<8 {
            for file in 0..<8 {
                guard let p = game.piece(at: Square(file: file, rank: rank)) else { continue }
                let base = (rank * 8 + file) * 12 + (p.color == .white ? 0 : 6)
                switch p.type {
                case .pawn:   x[base] = 1
                case .knight: x[base + 1] = 1
                case .bishop: x[base + 2] = 1
                case .rook:   x[base + 3] = 1
                case .queen:  x[base + 4] = 1
                case .king:   x[base + 5] = 1
                }
            }
        }
        x[768] = (game.sideToMove == .white) ? 1 : -1
        // Castling rights
        x[769] = game.whiteCanCastleKingside ? 1 : 0
        x[770] = game.whiteCanCastleQueenside ? 1 : 0
        x[771] = game.blackCanCastleKingside ? 1 : 0
        x[772] = game.blackCanCastleQueenside ? 1 : 0
        // En passant file (one-hot over 8 files; all zero when none)
        if let epFile = game.enPassantFile, (0..<8).contains(epFile) {
            x[773 + epFile] = 1
        }
        // Halfmove clock, normalized (50-move rule triggers at 100)
        x[781] = min(Float(game.halfmovesSincePawnOrCapture) / 100.0, 1.0)
        // Is the side to move in check?
        x[782] = game.isInCheck(game.sideToMove) ? 1 : 0
        // Attack maps: 64 squares attacked-by-white, 64 attacked-by-black.
        // This is what lets the network learn WHY a piece is dangerous.
        for rank in 0..<8 {
            for file in 0..<8 {
                let sq = Square(file: file, rank: rank)
                let idx = rank * 8 + file
                if game.isSquareAttacked(sq, by: .white) { x[783 + idx] = 1 }
                if game.isSquareAttacked(sq, by: .black) { x[847 + idx] = 1 }
            }
        }
        return x
    }
}
