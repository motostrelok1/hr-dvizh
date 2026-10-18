# HR Движ! — MVP ATS

Рабочее статическое приложение HR CRM в стилистике «Движ!» на основе исходных макетов этапа 1A и PostgreSQL/Supabase.

## Быстрый старт

Откройте [index.html](index.html) через локальный HTTP сервер (`python3 -m http.server 8080`) или настройте GitHub Pages для ветки `main`, папка `/ (root)`. Без настройки сервера приложение запускается в **деморежиме**: можно создавать вакансии и кандидатов, двигать их по воронке, вести заметки и задачи. Данные деморежима хранятся в localStorage только текущего браузера.

## Подключить Supabase

1. Подготовьте PostgreSQL 15+ с Supabase Auth.
2. Выполните в SQL Editor **по порядку**: `db/001_core_schema.sql`, затем `db/002_vacancy_pipeline.sql`, затем `db/003_pipeline_editor.sql`. Вторая миграция автоматически создаёт семь этапов для каждой новой вакансии.
3. Создайте в Supabase Auth первого пользователя и узнайте его User UID.
4. Под административной ролью выполните SQL (замените UUID и email):
```sql
begin;
insert into public.profiles(id,full_name,email)
values ('YOUR-AUTH-USER-UUID','Администратор HR','admin@example.com')
on conflict(id) do update set full_name=excluded.full_name,email=excluded.email;
with org as (insert into public.organizations(name) values ('Движ!') returning id)
insert into public.memberships(org_id,user_id,role)
select id,'YOUR-AUTH-USER-UUID','owner'::public.org_role from org;
commit;
```
5. В интерфейсе «Настройки» введите **Supabase Project URL** (HTTPS) и **publishable/anon key**, нажмите «Подключиться» и войдите под учётной записью пользователя. **Не используйте service_role или другие секретные ключи**.
6. Для отказов добавьте хотя бы одну запись в `rejection_reasons` для своей организации. Например: `insert into public.rejection_reasons (org_id,name) select id,'Не соответствует требованиям' from public.organizations where name='Движ!';`.

### Возможности

- Вакансии: создание, редактирование, статусы, поиск, счётчики.
- Воронка: автоматические этапы, подсветка просроченного SLA, карточки кандидатов, drag-and-drop. Настройка глубины, названий, порядка, типов и SLA каждого этапа (кнопка «⚙ Этапы»). Архивирование этапа без удаления истории.
- Кандидаты: создание отклика, карточка, чтение контактов через `candidates_safe`.
- Этапы: перевод через защищённую RPC `move_application`, причина отказа.
- Заметки: видимость «Только HR» / «Команда».
- Задачи: создание, сроки, выполнение.
- Supabase Auth и tenant RLS; адаптивное мобильное меню.
- Локальный автономный деморежим с сохранением данных браузера.

### Ограничения

Это **MVP, не законченный production HR-сервис**. Демоданные не синхронизируются с БД. Чат, календарь собеседований, импорт hh.ru, резюме, push/email и самостоятельное приглашение сотрудников не реализованы. Для продакшена нужны security review SQL/RLS, проверка ролей, storage, тестирование и резервные копии. Исходные макеты `design/*.dc.html` используют `support.js`, которого не было среди предоставленных файлов; рабочее приложение не использует этот файл.

### Структура

```text
index.html
app.css
app.js
pipeline-editor.js
db/001_core_schema.sql
db/002_vacancy_pipeline.sql
db/003_pipeline_editor.sql
design/*.dc.html
design/canvas.json
```
