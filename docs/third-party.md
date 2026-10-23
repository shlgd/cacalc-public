# Источники и сторонние компоненты

MIT в корне относится к собственному коду и документации cacalc.
Она не заменяет лицензии данных, моделей и зависимостей.

| Компонент | Источник / лицензия |
| --- | --- |
| Базовые продукты | Matvaretabellen, Norwegian Food Safety Authority, NLOD; источник и версия в catalog.manifest.json |
| Parakeet TDT 0.6B v3 | NVIDIA, CC BY 4.0; Core ML-конверсия FluidInference |
| multilingual E5 small | intfloat, MIT; закреплённая ревизия в prepare_e5.py |
| Qwen3-4B-Instruct-2507 | Qwen / Alibaba Cloud, Apache-2.0; экспериментальная MLX-конверсия mlx-community |
| FluidAudio | Пакет FluidInference, Apache-2.0 |
| SwiftTransformers | Пакет Hugging Face; уведомления вложены в ресурсы |
| MLX Swift LM | Пакет ml-explore; уведомления вложены в ресурсы |
| Исторический OFF-адаптер | Open Food Facts contributors, ODbL-1.0; реальные выгрузки не включены |

Полные сохранённые уведомления библиотек:
[ThirdPartyNotices.txt](../ios/Resources/ThirdPartyNotices.txt).
Версии Swift-пакетов закреплены в `ios/project.yml`, голосовых моделей —
в `ios/Resources/voice-models.json` с SHA-256.

Первоисточники:

- [API Matvaretabellen](https://www.matvaretabellen.no/api/)
- [Метаданные и лицензия Matvaretabellen](https://data.norge.no/en/datasets/9d082918-e3d4-4ae2-8efd-e7d025dfd52d/matvaretabellen)
- [Parakeet NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [Core ML Parakeet](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [multilingual E5 small](https://huggingface.co/intfloat/multilingual-e5-small)
- [Qwen](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- [MLX-конверсия Qwen](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit)

Синтетические тесты не являются справочником питания. Выгрузки и веса
загружаются отдельно с соблюдением условий их источников.
