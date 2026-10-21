# Foresight Chess

A chess app where **Stockfish** — the open-source chess engine — plays the game, while an on-device neural network learns from it.

## How it works

- **Stockfish** (embedded C++ engine) plays Black's moves at adjustable depth
- **KnowledgeNet** — an on-device neural network (911 inputs) learns from Stockfish's evaluations after every move (knowledge distillation), getting stronger over time
- **Adjustable foresight** — in-app slider (1-3) maps to Stockfish search depth 8/12/16
- **Export Network** — share the trained weights as JSON from Settings (appears after your first game)
- **First launch** downloads Stockfish's NNUE neural networks (~75MB total) with a progress screen; cached afterwards

## Requirements

- iOS 17+

## Building

Push to main triggers the unsigned IPA build via GitHub Actions. Download from workflow artifacts.

## Third-party software

This project embeds **Stockfish** (https://github.com/official-stockfish/Stockfish),
Copyright © The Stockfish developers, licensed under the **GNU General Public
License v3.0**. The full license text is in [COPYING.txt](COPYING.txt).

Because Stockfish is GPLv3, this entire project is distributed under GPLv3.

---
Built with Muse
