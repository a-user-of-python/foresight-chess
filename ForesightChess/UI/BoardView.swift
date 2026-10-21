// BoardView.swift
// Adaptive Chess — interactive chess board.
//
// The user always plays White, shown at the bottom of the board.
// Tap one of your pieces to select it (legal destinations get dots),
// tap a destination to move. Pawn promotion opens a picker sheet.
// The board also highlights the last move and a king in check.
//
// Accessibility: large high-contrast pieces, coordinate labels on the
// edges, and VoiceOver labels on every square.

import SwiftUI

struct BoardView: View {
    /// The live game. Read during body evaluation; the parent re-renders
    /// this view whenever the game state changes.
    let game: ChessGame

    @Binding var selectedSquare: Square?
    @Binding var lastMove: Move?

    /// False while the AI is thinking or the game is over.
    var interactionEnabled: Bool = true

    /// The color the human plays (always White in this app).
    var userColor: PieceColor = .white

    /// Called with the fully-formed move the user chose (promotion included).
    var onMove: (Move) -> Void

    /// Non-nil while the promotion picker sheet is up.
    @State private var promotionMoves: [Move]? = nil

    // Classic high-contrast board colors; readable in light and dark mode.
    private let lightSquare = Color(red: 0.94, green: 0.85, blue: 0.71)
    private let darkSquare = Color(red: 0.71, green: 0.53, blue: 0.39)
    private let labelSize: CGFloat = 30

    var body: some View {
        // Computed once per render so the 64 squares don't each
        // regenerate the legal move list.
        let targets = legalTargets
        let captures = captureTargets

        return GeometryReader { geo in
            let boardSide = min(geo.size.width - labelSize,
                                geo.size.height - labelSize)
            let sq = max(boardSide / 8, 1)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    rankLabels(square: sq)
                    VStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<8, id: \.self) { col in
                                    squareView(Square(file: col, rank: 7 - row),
                                               size: sq,
                                               targets: targets,
                                               captures: captures)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 0) {
                    Spacer().frame(width: labelSize)
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { col in
                            Text(String(UnicodeScalar(97 + col)!))
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: sq, height: labelSize)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .sheet(isPresented: promotionSheetPresented) {
            promotionSheet
        }
    }

    // MARK: - Squares

    private func squareView(_ square: Square,
                            size: CGFloat,
                            targets: Set<Square>,
                            captures: Set<Square>) -> some View {
        let isLight = (square.file + square.rank) % 2 == 1
        let piece = game.piece(at: square)

        return ZStack {
            Rectangle()
                .fill(isLight ? lightSquare : darkSquare)

            // Last-move highlight.
            if lastMove?.from == square || lastMove?.to == square {
                Rectangle().fill(Color.yellow.opacity(0.55))
            }

            // Selection highlight.
            if selectedSquare == square {
                Rectangle().fill(Color.blue.opacity(0.5))
            }

            // King in check.
            if isKingInCheck(on: square) {
                Rectangle().fill(Color.red.opacity(0.6))
            }

            if let piece = piece {
                Text(piece.glyph)
                    .font(.system(size: size * 0.74))
                    .foregroundColor(piece.color == PieceColor.white ? SwiftUI.Color.white : SwiftUI.Color(white: 0.1))
                    .shadow(color: piece.color == .white
                                ? .black.opacity(0.75)
                                : .white.opacity(0.4),
                            radius: 2, x: 0, y: 1)
            }

            // Legal-move indicators: dot for quiet moves, ring for captures.
            if targets.contains(square) {
                if captures.contains(square) {
                    Circle()
                        .stroke(Color.black.opacity(0.6), lineWidth: max(4, size * 0.08))
                        .padding(size * 0.07)
                } else {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: size * 0.3, height: size * 0.3)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { handleTap(square) }
        .accessibilityLabel(accessibilityLabel(for: square))
        .accessibilityAddTraits(.isButton)
    }

    private func rankLabels(square: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                Text("\(8 - row)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: labelSize, height: square)
            }
        }
    }

    // MARK: - Tap handling

    private func handleTap(_ square: Square) {
        guard interactionEnabled, promotionMoves == nil else { return }

        if let selected = selectedSquare {
            // Tapping the selected square again deselects it.
            if square == selected {
                selectedSquare = nil
                return
            }

            let moves = game.legalMoves(from: selected).filter { $0.to == square }
            if !moves.isEmpty {
                if moves.allSatisfy({ $0.promotion != nil }) {
                    // Pawn promotion: let the user pick the piece.
                    promotionMoves = moves
                } else {
                    onMove(moves[0])
                }
                return
            }

            // Not a legal destination — maybe select a different piece.
            if isSelectablePiece(at: square) {
                selectedSquare = square
            } else {
                selectedSquare = nil
            }
        } else {
            if isSelectablePiece(at: square) {
                selectedSquare = square
            }
        }
    }

    private func isSelectablePiece(at square: Square) -> Bool {
        guard let piece = game.piece(at: square),
              piece.color == userColor else { return false }
        return !game.legalMoves(from: square).isEmpty
    }

    // MARK: - Highlights

    private var legalTargets: Set<Square> {
        guard let selected = selectedSquare else { return [] }
        return Set(game.legalMoves(from: selected).map(\.to))
    }

    private var captureTargets: Set<Square> {
        guard let selected = selectedSquare else { return [] }
        return Set(game.legalMoves(from: selected)
            .filter { $0.isCapture || $0.isEnPassant }
            .map(\.to))
    }

    private func isKingInCheck(on square: Square) -> Bool {
        let side = game.sideToMove
        guard game.isInCheck(side) else { return false }
        guard let piece = game.piece(at: square) else { return false }
        return piece.type == .king && piece.color == side
    }

    // MARK: - Promotion sheet

    private var promotionSheetPresented: Binding<Bool> {
        Binding(
            get: { promotionMoves != nil },
            set: { if !$0 { promotionMoves = nil } }
        )
    }

    private var promotionSheet: some View {
        VStack(spacing: 24) {
            Text("Promote pawn to:")
                .font(.largeTitle)
                .bold()
                .multilineTextAlignment(.center)

            HStack(spacing: 20) {
                ForEach(promotionMoves ?? [], id: \.promotion) { move in
                    let type = move.promotion ?? .queen
                    Button {
                        promotionMoves = nil
                        onMove(move)
                    } label: {
                        Text(Piece(type: type, color: userColor).glyph)
                            .font(.system(size: 68))
                            .foregroundColor(userColor == PieceColor.white ? SwiftUI.Color.white : SwiftUI.Color(white: 0.1))
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .frame(width: 92, height: 92)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(18)
                    }
                    .accessibilityLabel("Promote to \(type.rawValue)")
                }
            }

            Button("Cancel") { promotionMoves = nil }
                .font(.title2)
                .padding(.top, 8)
        }
        .padding(36)
    }

    // MARK: - Accessibility

    private func accessibilityLabel(for square: Square) -> String {
        var text: String
        if let piece = game.piece(at: square) {
            let colorName = piece.color == .white ? "White" : "Black"
            text = "\(colorName) \(piece.type.rawValue) on \(square.algebraic)"
        } else {
            text = "Empty square \(square.algebraic)"
        }
        if selectedSquare == square { text += ", selected" }
        return text
    }
}
