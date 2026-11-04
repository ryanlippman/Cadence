import SwiftUI

struct AboutContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Music").font(.headline)
                Text("Every note is composed on your Mac as you listen: phrases, cadences, voice-leading, themes that return, and gradual changes of key, in four broad traditions (minimalist, impressionist, romantic and baroque). The pieces are original; they are not recordings or reproductions of existing works. Nothing is streamed or uploaded.")
                Text("Piano samples").font(.headline)
                Text("Salamander Grand Piano V3 (Yamaha C5), recorded by Alexander Holm and distributed by the FreePats project under Creative Commons Attribution 3.0 (CC BY 3.0). Cadence uses a subset of notes, velocity layers and release noises, trimmed, faded and stored losslessly; notes in between are pitch-shifted.")
                HStack(spacing: 16) {
                    Link("CC BY 3.0 licence", destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!)
                    Link("FreePats", destination: URL(string: "https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html")!)
                }
                Text("About the modulation").font(.headline)
                Text("The optional sound layer applies a smooth amplitude modulation (around 16 Hz for Focus, 9 Hz for Relax and 1–4 Hz for Sleep). It is inspired by published research on rhythmic auditory stimulation. Effects on concentration, relaxation and sleep vary between people, and some people notice none. Cadence is not a medical device and makes no medical or therapeutic claims.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About Cadence").font(.title2.weight(.semibold))
            AboutContent()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 460, height: 460)
    }
}
