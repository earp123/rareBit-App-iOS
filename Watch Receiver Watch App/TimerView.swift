//
//  TimerView.swift
//  Watch Receiver Watch App
//
//  Created by Sam Rall on 12/30/25.
//

import SwiftUI

struct TimerView: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack {
                Spacer()
                
                Text("45:00")
                    .font(.system(size: 72, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                
                Spacer()
            }
            .padding()
        }
    }
}

#Preview {
    TimerView()
}
