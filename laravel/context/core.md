# Laravel project

This is a **PHP / Laravel** application.

Structure (conventions):
- `routes/web.php`, `routes/api.php` — route definitions (the entry points).
- `app/Http/Controllers/` — controllers (`FooController`).
- `app/Models/` — Eloquent models.
- `resources/views/**.blade.php` — Blade templates (dotted names: `view('users.index')` ⇒ `resources/views/users/index.blade.php`).
- `database/migrations/` — schema migrations.
- `config/`, `app/Providers/` — config and service providers.

Tooling: `composer install`, `php artisan migrate`, `php artisan test`, `php artisan route:list`.
PSR-4 autoload is declared in `composer.json` (`autoload.psr-4`, default `App\\` ⇒ `app/`).

The structure map (`laravel_graph`) resolves routes → controllers → models/views and Blade `@extends`/`@include` between templates.
