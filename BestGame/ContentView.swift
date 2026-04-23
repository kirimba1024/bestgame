//
//  ContentView.swift
//  BestGame
//
//  Created by Kirill Osipov on 4/23/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            MetalView(clearColor: .init(red: 0.10, green: 0.12, blue: 0.18, alpha: 1.0))
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
