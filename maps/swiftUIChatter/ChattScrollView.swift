//
//  ChatScrollView.swift
//  swiftUIChatter
//
//  Created by Niki Murthy on 1/15/26.
//

import SwiftUI
import MapKit

struct ChattView: View {
    @Environment(ChattViewModel.self) private var vm
    
    let chatt: Chatt
    let onTrailingEnd: Bool
    
    var body: some View {
        VStack(alignment: onTrailingEnd ? .trailing : .leading, spacing: 4) {
            if let msg = chatt.message, !msg.isEmpty {
                Text(onTrailingEnd ? "" : chatt.name ?? "")
                    .font(.subheadline)
                    .foregroundColor(.purple)
                    .padding(.leading, 4)
                
                HStack(alignment: .top, spacing: 10) {
                    if onTrailingEnd && chatt.geodata != nil {
                        PinView()
                            .foregroundStyle(.white)
                    }
                    
                    Text(msg)
                    
                    if !onTrailingEnd && chatt.geodata != nil {
                        PinView()
                            .foregroundStyle(.blue)
                    }
                }
                
                Text(chatt.timestamp ??  "")
                    .font(.caption2)
                    .foregroundColor(.gray)
                
                Spacer()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder
    func PinView() -> some View {
        Image(systemName: "mappin.and.ellipse")
            .font(.caption)
            .padding(.top, 3)
            .onTapGesture {
                if let geodata = chatt.geodata {
                    vm.selected = chatt
                    vm.cameraPosition = .camera(MapCamera(
                        centerCoordinate: CLLocationCoordinate2D(latitude: geodata.lat, longitude: geodata.lon), distance: 500, heading: 0, pitch: 60))
                    vm.showMap.toggle()
                }
            }
    }
}

struct ChattScrollView: View {
    @Environment(ChattViewModel.self) private var vm
    
    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(ChattStore.shared.chatts) {
                    ChattView(chatt: $0, onTrailingEnd: $0.name == vm.onTrailingEnd)
                }
            }
        }
    }
}
