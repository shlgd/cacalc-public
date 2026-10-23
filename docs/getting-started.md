# Сборка своей версии

## Требования

Mac с Xcode, содержащим SDK iOS 26, Python 3.11+ и XcodeGen.
Для подготовки Core ML удобно использовать Apple Silicon. Для установки на
свой iPhone нужны собственная Apple development team и доступные ей capabilities
HealthKit, Keychain Sharing и расширения. Возможности подписи зависят от аккаунта.

Исходники сами по себе не содержат каталог SQLite и поисковую Core ML-модель.
Сначала подготовьте ресурсы, затем запускайте XcodeGen. Для подготовки E5 нужно
не менее 25 ГБ свободного места; перед сборками и Swift-проверками — не менее
20 ГБ. Не запускайте тяжёлую подготовку при нехватке места.

```sh
xcodebuild -version
xcrun --find swiftc
python3 --version
xcodegen --version
df -h .
```

Ниже команды выполняются из корня вашей копии репозитория, кроме явно указанного
перехода в `ios`. Все зависимости устанавливаются в отдельное окружение.

## 1. Базовый каталог

Поставщик — Matvaretabellen / Norwegian Food Safety Authority. Русские названия
в `data/curation/basic-food-names-ru.txt` связаны с устойчивыми ID поставщика.
Пищевая ценность берётся из источника, не генерируется моделью.

```sh
mkdir -p data/matvaretabellen
curl --fail --location https://www.matvaretabellen.no/api/en/foods.json --output data/matvaretabellen/foods.json
shasum -a 256 data/matvaretabellen/foods.json
```

Закреплённый снимок: SHA-256
`89b8f5f494a79731bf7d8d98065ee66c55263ccdbb519e7c87941218be6c948d`.
Сверьте результат до импорта. Если официальный endpoint изменился, остановитесь:
для нового снимка нужно отдельно проверить ID, единицы, полноту и результаты
импорта. Не подменяйте ожидаемую сумму лишь ради успешной проверки.

```sh
python3 -B tools/build_basic_catalog.py
python3 -B tools/check_basic_catalog.py
```

Выход: `ios/Resources/catalog.sqlite`, manifest и отчёт импорта в `reports/`.
Отчёт и SQLite остаются локальными. Это выбранные базовые продукты, без
штрихкодов и без обещания покрытия всего рынка. Исторический OFF V1 builder
не заменяет этот путь.

## 2. Семантический поиск

Поисковая модель обязательна для текущего описания XcodeGen. Подготовка скачивает
закреплённую multilingual E5 small, конвертирует её в Core ML FLOAT32 и создаёт
векторы поставляемого каталога. Личный дневник не читается.

Ранее использованное окружение конвертации: Python 3.11, torch 2.7.1,
transformers 4.57.6, coremltools 9.0, numpy 1.26.4 и sentencepiece.
Это описание окружения, а не гарантия совместимости любой версии macOS/Xcode.

```sh
python3.11 -m venv .venv-search
.venv-search/bin/python -m pip install --no-cache-dir torch==2.7.1 transformers==4.57.6 coremltools==9.0 numpy==1.26.4 sentencepiece
.venv-search/bin/python tools/SearchBench/prepare_e5.py
```

Выход: `data/search-e5/FoodEmbedding.mlpackage` и `data/search-e5/FoodSearch/`.
Не коммитьте веса, токенизатор, векторы и кэши. После подготовки можно удалить
только созданное вами окружение `.venv-search`; готовые ресурсы нужны сборке.

## 3. Проект и подпись

```sh
cd ios
xcodegen generate
open Cacalc.xcodeproj
```

Выберите scheme `Cacalc`. В Signing & Capabilities задайте свою team и уникальные
bundle identifiers основного приложения и `RecordingActivity`. Если меняете
идентификаторы в `project.yml`, согласованно обновите значения приватных
Keychain-групп, общей nutrition-группы и `NutritionWidgetKeychainGroup` обоих
targets, затем повторите генерацию. Приватная группа основного приложения
остаётся первой. Проверьте доступность HealthKit и групп у вашей team.

Выберите свой iPhone и запустите Run. Секреты, provisioning profiles и `.p12`
не добавляйте в Git. Для подписи чужой установки не используйте свои личные
учётные данные. Перед обновлением существующей установки сохраните проверенную
внешнюю резервную копию; не удаляйте приложение ради устранения ошибки миграции.

Репозиторий содержит `project.yml` вместо персонального сгенерированного
проекта. Swift-пакеты закреплены exactVersion в этом файле. Настройки своей
team держите локально, проверяйте diff перед отправкой.

## 4. Голос на iPhone

При первом использовании загрузите модели через экран подготовки голоса
в приложении. Версии, размеры и SHA-256 заданы в
`ios/Resources/voice-models.json`. Обычная диктовка использует Parakeet;
Qwen не является автоматическим fallback. Некоторые инструменты подготовки
умеют загружать обе модели и требуют существенно больше места.

`tools/download_voice_models.py` — отдельный инструмент Mac. Его локальная
папка не переносится на телефон автоматически. Не запускайте его для обычной
установки приложения и не добавляйте полученные веса в репозиторий.

Ключ Polza не нужен для новой локальной live-диктовки. Для исторического
облачного пути используйте собственный ключ, вводимый только в приложении.

## Проверки

Лёгкие проверки Python из корня:

```sh
python3 -B -m unittest discover -s tests -v
python3 -B tools/test_legacy_log_tools.py
python3 -B tools/check_usage_coverage.py
```

Swift-проверки на Mac с достаточным свободным местом, без моделей и сети:

```sh
sh tools/check_label_parser.sh
sh tools/check_meal_pipeline.sh
sh tools/check_meal_pairs.sh
sh tools/check_voice_verification.sh
sh tools/check_nutrition_widget.sh
sh tools/check_usage_telemetry.sh
sh tools/check_storage_maintenance.sh
sh tools/check_storage_usage_probe.sh
```

Они используют временные хранилища. Не задавайте им путь к настоящей базе.
Модельные XCTest отдельно требуют `CACALC_RUN_MODEL_TESTS=1`; наличие весов
не означает разрешения на сетевые или платные проверки. Успешный тест
парсера не доказывает точность ASR, а сборка не заменяет проверку на устройстве.

## Если что-то не работает

- XcodeGen не находит `FoodEmbedding.mlpackage`: завершите шаг подготовки E5.
- Не найден каталог: сначала создайте `ios/Resources/catalog.sqlite`.
- Ошибка подписи: проверьте оба targets, team, identifiers и capabilities.
- Голос не готов: проверьте завершение загрузки и доступ к микрофону.
- Ошибка личной базы: сохраните файлы, не очищайте контейнер и не создавайте
  пустую базу вместо прежней. Для отчёта используйте обезличенный пример.
