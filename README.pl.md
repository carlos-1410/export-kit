# ExportKit

Przenośne eksporty Ruby z jawnym limitem rozmiaru.

ExportKit zamienia zwykłe dane Ruby, jawne tabele albo dokumenty z wieloma sekcjami na JSON, CSV,
archiwa ZIP z tabelami CSV oraz PDF. Strumieniuje wiersze, zatrzymuje zapis po przekroczeniu limitu,
neutralizuje formuły arkusza, sprząta częściowe pliki tymczasowe i potrafi sprawdzić wynikowy artefakt.

Pełna dokumentacja API i przykłady znajdują się w angielskim [README.md](README.md). Ten plik
podsumowuje kontrakt integracyjny po polsku.

## Instalacja

```ruby
gem "export_kit", "~> 0.1.0"
```

Wymagany jest Ruby 3.4 lub nowszy. Rdzeń nie uruchamia Rails ani Active Record. Adapter modeli
włącza się jawnie przez `require "export_kit/active_record"`.

## Pojedyncza tabela

```ruby
require "export_kit"

table = ExportKit::Table.new(
  columns: %i[number total],
  labels: { number: "Numer", total: "Kwota" },
  rows: [{ number: "GV-001", total: "149.00" }]
)

result = ExportKit.render(table, format: :csv, max_bytes: 5 * 1024**2)

if result.success?
  artifact = result.value!
  begin
    send_data artifact.file.read, type: artifact.content_type
  ensure
    artifact.close!
  end
end
```

Każdy wiersz musi mieć dokładnie zadeklarowane kolumny. Kolejność kolumn jest stabilna. Wartości
CSV zaczynające się od `=`, `+`, `-` albo `@` dostają apostrof, aby arkusz nie wykonał ich jako
formuły. `rows` może być callbackiem przyjmującym blok `emit`, dzięki czemu nie trzeba budować całej
tablicy w pamięci.

## Formaty

- zwykły Hash lub Array: `json`;
- `ExportKit::Table`: `json` albo `csv`;
- `ExportKit::Document`: `json`, `csv_zip` albo `pdf`.

Dokument składa się z wersjonowanego identyfikatora, metadanych, sekcji i nazwanych zestawów
rekordów. ZIP zawiera osobny CSV dla każdego niepustego zestawu oraz `manifest.csv`. PDF wymaga
jawnej ścieżki do fontu Unicode dostarczonego przez aplikację.

## Wynik i sprzątanie

Oczekiwane odmowy nie rzucają wyjątku:

- `export_format_unsupported` — nieobsługiwany format;
- `export_too_large` — przekroczony limit bajtów;
- `export_render_failed` — niepoprawne dane albo wynik renderera.

Szczegóły błędu mogą wskazać sekcję, zestaw, wiersz i kolumnę, ale nie zawierają wartości danych.
Błędy programistyczne propagują wyjątek po usunięciu pliku częściowego. Udany artefakt należy
zawsze zamknąć przez `close!`/`cleanup` w `ensure`.

## Active Record

```ruby
require "export_kit/active_record"

table = ExportKit.records(
  policy_scope(Order).reorder(nil),
  fields: %i[id number total_minor],
  batch_size: 500
)
```

Adapter wymaga relacji już ograniczonej przez aplikację. Może także pilnować kompletnej klasyfikacji
kolumn modelu: każda kolumna trafia wtedy na jawną allowlistę albo denylistę z powodem. To bezpiecznik
schematu, nie zamiennik Pundita ani innej autoryzacji.

Relacja do stronicowania musi być bez `order`, `offset`, `group` i `distinct` oraz mieć pojedynczy
klucz główny. Adapter stronicuje po kluczu i respektuje istniejący `limit`.

## Granica odpowiedzialności

Biblioteka odpowiada za mechanikę formatów, limity zapisu, neutralizację formuł, sprzątanie i
walidację struktury. Aplikacja odpowiada za:

- uwierzytelnienie, autoryzację i zakres danych;
- spójność odczytu;
- minimalizację danych i zgodność z wymaganiami prywatności;
- szyfrowanie, storage, pobieranie i retencję;
- zaufanie do własnych rendererów.

## Rozwój i wydania

```bash
bin/setup
bundle exec rake test
bundle exec rubocop
gem build export_kit.gemspec
```

Wydania idą z GitHub Actions do RubyGems.org przez OIDC Trusted Publishing, bez długowiecznego
tokena w sekretach repo. Szczegóły: [docs/releasing.md](docs/releasing.md).

Kod jest dostępny na licencji [MIT](LICENSE.txt).
