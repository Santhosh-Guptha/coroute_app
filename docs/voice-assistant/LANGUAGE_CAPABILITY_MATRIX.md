# CoRoute Multilingual Voice Assistant: Language Capability Matrix & Code-Switching Strategy

> **Document ID**: `DOC-VA-02`  
> **Milestone**: Milestone 3 — Messaging, Recipient Resolution & 12-Language Expansion  
> **Target Locales**: 12 Languages across Indo-Aryan and Dravidian families  
> **Status**: APPROVED  

---

## 1. Supported Language Matrix

CoRoute riders span all major motorcycle touring regions across India—from Leh-Ladakh, Spiti, and the Northeast corridors to the Western Ghats and coastal highways. The voice assistant targets **12 Indian languages** with native Indian-English code-switching:

| Language | Language Family | Locale Baseline | Script Code | Example Natural Mixed Utterance | Primary Intent |
| :--- | :--- | :---: | :---: | :--- | :--- |
| **Telugu** | Dravidian | `te-IN` | `Telu` | *“Rohit ki message send chey: Five minutes lo reach avtha.”* | `SEND_MESSAGE` |
| **Hindi** | Indo-Aryan | `hi-IN` | `Deva` | *“Sab riders ko alert bhejo: Agle toll gate pe ruko.”* | `BROADCAST_ALERT` |
| **English** | Indo-European | `en-IN` | `Latn` | *“Find nearest petrol pump on route within five kilometres.”* | `FIND_ESSENTIALS` |
| **Tamil** | Dravidian | `ta-IN` | `Taml` | *“Voice volume konjam kammi pannu.”* | `SET_VOICE_VOLUME` |
| **Kannada** | Dravidian | `kn-IN` | `Knda` | *“Next petrol bunk find maadi.”* | `FIND_ESSENTIALS` |
| **Marathi** | Indo-Aryan | `mr-IN` | `Deva` | *“Pudhil stop kiti lamb ahe?”* | `QUERY_TRIP_STATUS` |
| **Malayalam** | Dravidian | `ml-IN` | `Mlym` | *“Rohit-inu private intercom request ayakkuka.”* | `REQUEST_INTERCOM` |
| **Bengali** | Indo-Aryan | `bn-IN` | `Beng` | *“Group alert pathao: Road block ahe.”* | `BROADCAST_ALERT` |
| **Gujarati** | Indo-Aryan | `gu-IN` | `Gujr` | *“Trip summary vancho.”* | `QUERY_TRIP_STATUS` |
| **Punjabi** | Indo-Aryan | `pa-IN` | `Guru` | *“Agla stop kithe hai?”* | `QUERY_TRIP_STATUS` |
| **Odia** | Indo-Aryan | `or-IN` | `Orya` | *“Aau kete dur achhi destination?”* | `QUERY_TRIP_STATUS` |
| **Assamese** | Indo-Aryan | `as-IN` | `Beng` | *“Aamar speed kiba beshi hoise neki?”* | `QUERY_TRIP_STATUS` |

---

## 2. Indian-English Code-Switching Grammar Engine

### Linguistic Reality of Motorcycle Touring
Riders almost never speak single-language textbook sentences while riding. Instead, they code-switch dynamically:
1. **English Technical Terms + Regional Grammar Particles**:
   - Technical nouns: *“message”*, *“intercom”*, *“volume”*, *“petrol pump”*, *“speed”*, *“puncture”*, *“toll gate”*, *“battery”*.
   - Dravidian markers:
     - Telugu dative/benefactive `-ki` / `-ku` (*“Rohit-ki message chey”*).
     - Tamil dative `-ku` / `-kku` (*“Rohit-ku request anupu”*).
     - Kannada dative `-ge` / `-ke` (*“Rohit-ge message maadi”*).
     - Malayalam dative `-nu` / `-inu` (*“Rohit-inu request ayakkuka”*).
   - Indo-Aryan postpositions:
     - Hindi dative *“ko”* (*“Rohit ko message bhejo”*).
     - Marathi dative *“la”* (*“Rohit la message pathva”*).
     - Bengali dative *“ke”* (*“Rohit ke message pathao”*).
     - Gujarati dative *“ne”* (*“Rohit ne message moko”*).

### Intent Normalization Strategy
Instead of building 12 separate NLU pipelines, `LanguageResolver` and `IntentResolver` utilize an **Intent Canonicalization Matrix**:
- Text is normalized: lowercased, punctuation stripped, numerals expanded.
- Regional verb stems mapping to actions (`chey`, *karo*, *pannu*, *maadi*, *pathva*, *bhejo*, *send*, *call*) resolve to root action verbs.
- Postposition suffix stripping (`Rohit-ki` → `Rohit`, `Rohit-ko` → `Rohit`, `Rohit-ku` → `Rohit`, `Rohit-ge` → `Rohit`) cleanly extracts the recipient entity slot.

---

## 3. Platform Offline Language Support & Fallback Strategy

Because cellular networks drop completely in mountain corridors (e.g., Zoji La, Chang La, Western Ghats forests), offline capability must be negotiated realistically:

| Language | Android On-Device Speech Pack | iOS Speech Recognition | CoRoute Embedded Offline Fallback |
| :--- | :---: | :---: | :---: |
| **English (`en-IN`)** | Highly Available (Preloaded) | Available | Full Intent Grammar Engine |
| **Hindi (`hi-IN`)** | Highly Available (Downloadable) | Available | Full Intent Grammar Engine |
| **Telugu (`te-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Tamil (`ta-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Kannada (`kn-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Marathi (`mr-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Bengali (`bn-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Gujarati (`gu-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Malayalam (`ml-IN`)**| Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Punjabi (`pa-IN`)** | Available (Android 12+ GMS) | Available (iOS 16+) | Normalized Phonetic Grammar Engine |
| **Odia (`or-IN`)** | Device Dependent | Cloud-assisted | Fallback to English/Hindi with verbal notice |
| **Assamese (`as-IN`)**| Device Dependent | Cloud-assisted | Fallback to English/Hindi with verbal notice |

### Offline Limitation Protocol (VA-004 Acceptance Criteria)
If an offline rider attempts to use a language without an installed on-device speech pack:
1. The engine falls back to `en-IN` or the user's secondary fallback locale.
2. The voice assistant explicitly announces the constraint:  
   *“Offline mode active. Speech pack for this language is not downloaded. Operating in English.”*
3. The app **never** silently attempts cloud recognition that hangs or stalls when cellular signal is zero.

---

## 4. `VoiceCapabilityRegistry` & 15-Item Test Corpus

The `VoiceCapabilityRegistry` (`coroute_app/lib/data/services/voice/voice_capability_registry.dart`) programmatically provides the truthful runtime capability matrix across Android, iOS, and Web.

It includes a comprehensive 15-item evaluation corpus tested across all 12 target locales, covering:
1. **Mixed Code-Switching**: English technical tokens mixed with regional grammar particles.
2. **Numbers & Quantities**: Spoken numeral recognition in Indian context (`five minutes`, `two point five km`, `80 percent`).
3. **Distances & Navigation**: Radius constraints, navigation instructions, and destination queries.
4. **Accents & Colloquialisms**: Variations in cadence, tone, and regional idioms.
5. **Ambiguity & Disambiguation**: Shared callsigns (`Which Rohit? Rohit Sharma or Rohit Verma?`).
