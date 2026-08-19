// swift-tools-version:6.0
import PackageDescription

// NOTA DE EMPACOTAMENTO: nenhum target usa `resources:` de propósito.
// O SwiftPM gera um `Bundle.module` que aponta para um .bundle na RAIZ do .app, o que
// viola o formato de bundle da Apple e faz o `codesign` falhar com "unsealed contents
// present in the root directory". Recursos (modelo GGUF, .lproj) são copiados para
// Contents/Resources pelo scripts/make-app.sh e lidos via Bundle.main.
//
// O whisper.cpp é compilado à parte pelo scripts/build-whisper.sh e vive em vendor/.
// Rode-o antes do primeiro `swift build`.

let package = Package(
    name: "Capita",
    platforms: [.macOS(.v15)],
    targets: [
        // Ponte para a API C do whisper.cpp.
        .target(
            name: "WhisperC",
            path: "Sources/WhisperC",
            cSettings: [
                .headerSearchPath("../../vendor/whisper/include")
            ]
        ),

        .executableTarget(
            name: "Capita",
            dependencies: ["WhisperC"],
            path: "Sources/Capita",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                // Metal e Accelerate são exigidos pelo backend do ggml.
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-Lvendor/whisper/lib",
                    "-lwhisper",
                    "-lggml", "-lggml-base", "-lggml-cpu",
                    "-lggml-metal", "-lggml-blas",
                ]),
            ]
        ),

        // Spike de validação: prova que o CoreAudio process tap captura o áudio do
        // sistema sem exigir privilégios de administrador. Pré-requisito de todo o
        // projeto — ver plano, "A descoberta que reorientou o plano".
        .executableTarget(
            name: "TapSpike",
            path: "Sources/TapSpike",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
