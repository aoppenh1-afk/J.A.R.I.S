# Privacy and Routing

## Local mode

Audio stays in the app process and is transcribed by Parakeet Core ML. Response text is spoken by `AVSpeechSynthesizer`. No Deepgram client is created.

## Cloud mode

A later native Deepgram provider may send microphone audio and response text to Deepgram. Failure remains visible and does not silently change modes.

## Auto mode

Local speech runs first. Cloud fallback requires explicit consent and configured Keychain credentials. Providers are not raced, and an ambiguous timeout does not resend the utterance.

Speech routing is separate from Hermes reasoning. Even in local speech mode, transcript text may reach the model provider configured in Hermes; the product UI must disclose that boundary.
