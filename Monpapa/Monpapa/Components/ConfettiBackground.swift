
//  ConfettiBackground.swift
//  Monpapa
//
//  Декоративный фон с разноцветными элементами
//

import SwiftUI

// MARK: - Модель частицы

struct ConfettiParticle: Identifiable {
    let id = UUID()
    let x: CGFloat        // позиция X (0...1)
    let y: CGFloat        // позиция Y (0...1)
    let size: CGFloat     // размер
    let rotation: Double  // угол поворота
    let color: Color      // цвет
    let shape: ParticleShape // форма
    
    enum ParticleShape {
        case circle
        case star
        case diamond
        case rectangle
    }
}

// MARK: - ConfettiBackground

struct ConfettiBackground: View {
    let particleCount: Int
    
    @State private var particles: [ConfettiParticle] = []
    
    init(particleCount: Int = 30) {
        self.particleCount = particleCount
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Фон
                MPColors.background
                    .ignoresSafeArea()
                
                // Частицы
                ForEach(particles) { particle in
                    particleView(particle)
                        .position(
                            x: particle.x * geo.size.width,
                            y: particle.y * geo.size.height
                        )
                }
            }
            .onAppear {
                generateParticles()
            }
        }
    }
    
    @ViewBuilder
    private func particleView(_ particle: ConfettiParticle) -> some View {
        switch particle.shape {
        case .circle:
            Circle()
                .fill(particle.color)
                .frame(width: particle.size, height: particle.size)
        case .star:
            Image(systemName: "star.fill")
                .font(.system(size: particle.size))
                .foregroundColor(particle.color)
                .rotationEffect(.degrees(particle.rotation))
        case .diamond:
            Rectangle()
                .fill(particle.color)
                .frame(width: particle.size, height: particle.size)
                .rotationEffect(.degrees(45))
        case .rectangle:
            RoundedRectangle(cornerRadius: 2)
                .fill(particle.color)
                .frame(width: particle.size * 1.5, height: particle.size * 0.6)
                .rotationEffect(.degrees(particle.rotation))
        }
    }
    
    private func generateParticles() {
        let colors: [Color] = [
            MPColors.accentCoral.opacity(0.6),
            MPColors.accentYellow.opacity(0.6),
            MPColors.accentBlue.opacity(0.6),
            MPColors.accentGreen.opacity(0.6),
            MPColors.accentCoral.opacity(0.3),
            MPColors.accentYellow.opacity(0.3),
        ]
        
        let shapes: [ConfettiParticle.ParticleShape] = [
            .circle, .circle, .star, .diamond, .rectangle
        ]
        
        particles = (0..<particleCount).map { _ in
            ConfettiParticle(
                x: CGFloat.random(in: 0.05...0.95),
                y: CGFloat.random(in: 0.02...0.98),
                size: CGFloat.random(in: 4...10),
                rotation: Double.random(in: 0...360),
                color: colors.randomElement()!,
                shape: shapes.randomElement()!
            )
        }
    }
}

// MARK: - Preview

#Preview("Конфетти") {
    ConfettiBackground()
}
