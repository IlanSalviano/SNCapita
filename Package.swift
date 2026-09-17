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
    dependencies: [
        // Diarização de locutor rodando na Neural Engine. Escolhido por conseguir
        // trabalhar 100% offline com modelos embarcados no bundle — requisito do
        // projeto, já que o app precisa funcionar numa máquina sem rede nem instalações.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
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
            dependencies: [
                "WhisperC",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Capita",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
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

        // Spike de validação da Fase 3: diariza uma gravação e imprime quem falou
        // quando, para medir qualidade e tempo antes de integrar ao app.
        .executableTarget(
            name: "DiarizeSpike",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/DiarizeSpike"
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

        // Spike de validação da detecção de reunião: mostra quais processos estão com o
        // microfone aberto, que é o sinal capaz de distinguir uma reunião de um vídeo.
        .executableTarget(
            name: "MeetSpike",
            path: "Sources/MeetSpike",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
