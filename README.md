# Foresight Chess

A chess app where Apple's on-device AI (Foundation Models) plays the game, consulting a chess neural network as its reference.

## How it works

- **Foundation Models** (iOS 26+, Apple Intelligence devices) chooses the moves and explains its reasoning
- **KnowledgeNet** — an on-device neural network (911 inputs, trained from scratch) evaluates positions as the AI's chess reference
- **Adjustable foresight** — set how many moves ahead the AI can see (1-3, in-app slider)
- The network learns from every game and gets better over time

## Requirements

- iOS 17+ to run (neural network plays directly)
- iOS 26+ with Apple Intelligence for the Foundation Models player

## Building

Push to main triggers the unsigned IPA build via GitHub Actions. Download from workflow artifacts.
