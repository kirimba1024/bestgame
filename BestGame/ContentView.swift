//
//  ContentView.swift
//  BestGame
//
//  Created by Kirill Osipov on 4/23/26.
//

import Metal
import SwiftUI

struct ContentView: View {
    private static let defaultClearColor = MTLClearColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1.0)

    var body: some View {
        ZStack {
            MetalView(clearColor: Self.defaultClearColor)
                .ignoresSafeArea()
            WindowLifecycleView()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

#Preview {
    ContentView()
}
