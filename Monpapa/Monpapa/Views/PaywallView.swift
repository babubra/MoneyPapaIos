//
//  PaywallView.swift
//  Monpapa
//
//  Экран подписки. Открывается:
//    • из Settings → "Оформить Premium"
//    • автоматически при получении 402 от backend (AI trial исчерпан)
//
//  TODO для production: интегрировать StoreKit 2.
//    let products = try await Product.products(for: ["monpapa.premium.monthly"])
//    let result = try await products.first?.purchase()
//    case .success(let verification): try checkVerified(verification)
//    POST /api/v1/subscription/verify { receipt_data: jws_payload, ... }
//
//  Сейчас "Оформить подписку" дёргает SubscriptionService.purchaseStub() —
//  backend в DEV-режиме выдаёт 30 дней Premium.
//

import SwiftUI

struct PaywallView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var subscription = SubscriptionService.shared

    @State private var purchaseError: String?

    var body: some View {
        ZStack {
            MPColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: MPSpacing.lg)

                hero

                Spacer(minLength: MPSpacing.xl)

                benefitsList
                    .padding(.horizontal, MPSpacing.lg)

                Spacer()

                priceLabel
                    .padding(.bottom, MPSpacing.xs)

                ctaButton
                    .padding(.horizontal, MPSpacing.lg)
                    .padding(.bottom, MPSpacing.lg)

                if let purchaseError {
                    Text(purchaseError)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(MPColors.accentCoral)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, MPSpacing.lg)
                        .padding(.bottom, MPSpacing.sm)
                }

                stubFooter
                    .padding(.bottom, MPSpacing.md)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(MPColors.textSecondary)
                    .padding(10)
                    .background(MPColors.textSecondary.opacity(0.08))
                    .clipShape(Circle())
            }
            .padding(.trailing, MPSpacing.lg)
            .padding(.top, MPSpacing.sm)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: MPSpacing.md) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                MPColors.accentCoral.opacity(colorScheme == .dark ? 0.25 : 0.15),
                                MPColors.accentYellow.opacity(colorScheme == .dark ? 0.15 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "crown.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [MPColors.accentCoral, MPColors.accentYellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("paywall.title")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(MPColors.textPrimary)
        }
    }

    // MARK: - Benefits

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: MPSpacing.md) {
            benefitRow(icon: "wand.and.stars", text: "paywall.benefit.ai")
            benefitRow(icon: "mic.fill", text: "paywall.benefit.voice")
            benefitRow(icon: "heart.fill", text: "paywall.benefit.support")
        }
    }

    private func benefitRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: MPSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(MPColors.accentCoral.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(MPColors.accentCoral)
            }
            Text(text)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundColor(MPColors.textPrimary)
            Spacer()
        }
    }

    // MARK: - Price + CTA

    private var priceLabel: some View {
        Text("paywall.price")
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundColor(MPColors.textSecondary)
    }

    private var ctaButton: some View {
        Button {
            Task { await tapPurchase() }
        } label: {
            HStack(spacing: 10) {
                if subscription.isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text("paywall.cta")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [MPColors.accentCoral, MPColors.accentCoral.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(MPCornerRadius.pill)
            .shadow(color: MPColors.accentCoral.opacity(0.3), radius: 8, y: 4)
        }
        .disabled(subscription.isBusy)
    }

    private var stubFooter: some View {
        Text("⚠️ DEV stub — реальный StoreKit добавится позже")
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundColor(MPColors.textSecondary.opacity(0.7))
            .multilineTextAlignment(.center)
    }

    // MARK: - Actions

    private func tapPurchase() async {
        purchaseError = nil
        do {
            try await subscription.purchaseStub()
            // Успех → закрываем paywall
            dismiss()
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}

#Preview {
    PaywallView()
}
