# NotchApp («Чёлка») — правила для ИИ-ассистента

- Swift Package. Сборка: `swift build --disable-sandbox -c release`. Установка: `./build_app.sh` (ставит в /Applications и перезапускает).
- После изменений переводчика обязательно: `.build/release/NotchApp --selftest-translate` (Apple-перевод + ИИ-шлифовка, 7 фраз). Не говорить «готово», пока не 7 из 7.
- Переводчик (Translate.swift): Apple Translation переводит мгновенно, затем `AIPolish` через Ollama (qwen2.5:7b, локально) делает текст естественнее. Если Ollama нет или ответ подозрительный — остаётся перевод Apple. Переключатель «✨ ИИ» в окне переводчика.
- ИИ-функции (AI.swift): «Скриншот → объяснить» (Vision OCR + qwen2.5:7b, без текста — qwen2.5vl), поиск по смыслу в заметках (NotesSearch: эмбеддинги, предпочтительно bge-m3; nomic-embed-text плохо понимает русский). Самопроверка: `.build/release/NotchApp --selftest-ai`.
- Живой тест через управление компьютером: приложение не находится в индексе (computer_resolve_access не видит NotchApp) — проверку интерфейса делает пользователь.
- Итог задачи — в Obsidian «Журналы ИИ/Claude.md» (Просили / Сделано / Проверено / Важно).
