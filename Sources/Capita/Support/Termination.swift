import Foundation

/// Encerra o processo sem rodar os destrutores estáticos do C++.
///
/// O whisper.cpp guarda os dispositivos Metal num vetor global. Ao destruí-lo, na saída do
/// processo, o ggml exige que todo buffer já tenha sido liberado —
/// `GGML_ASSERT([rsets->data count] == 0)`, com o comentário "most likely you haven't
/// deallocated all Metal resources before exiting" — e aborta se algum sobrou. Sair com
/// uma transcrição em curso cai exatamente nesse assert, e o crash log vem depois de tudo
/// ter funcionado.
///
/// Não é um vazamento nosso: o `whisper_context` é liberado no `deinit` do `WhisperEngine`,
/// e um `--smoke-transcribe` que roda até o fim encerra limpo. O que existe é uma janela —
/// parar de gravar dispara a transcrição, e fechar o app nos minutos seguintes encontra o
/// contexto vivo. Interromper o whisper para liberá-lo antes de sair não salvaria nada:
/// a transcrição só é escrita em disco quando termina, então o trabalho está perdido de
/// qualquer forma. O que se ganha é o processo morrer em silêncio, como deve.
///
/// O preço de `_exit` é pular os `atexit` — inclusive o flush do stdout, que é bufferizado
/// quando a saída vai para um pipe (`make smoke-record | tail`). Daí o flush explícito.
enum Termination {

    static func exitNow(_ code: Int32 = 0) -> Never {
        // Escritas recentes em UserDefaults são assíncronas; sem isto, uma preferência
        // mudada segundos antes de sair não chegaria ao disco.
        UserDefaults.standard.synchronize()
        fflush(nil)
        _exit(code)
    }
}
