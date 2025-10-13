import SwiftUI
import AVKit

struct LaunchVideoView: View {
    @State private var player = AVPlayer()
    @State private var isFinished = false

    var body: some View {
        ZStack {
            if isFinished {
                // Une fois la vidéo terminée → HomeView
                MainTabView() // ou ta HomeView
                    .transition(.opacity)
            } else {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        if let path = Bundle.main.path(forResource: "intro", ofType: "mp4") {
                            player = AVPlayer(url: URL(fileURLWithPath: path))
                            player.play()
                            
                            // Détecte la fin de la vidéo
                            NotificationCenter.default.addObserver(
                                forName: .AVPlayerItemDidPlayToEndTime,
                                object: player.currentItem,
                                queue: .main
                            ) { _ in
                                withAnimation(.easeOut(duration: 0.6)) {
                                    isFinished = true
                                }
                            }
                        }
                    }
            }
        }
    }
}
