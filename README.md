# ExportKit

Lokalny gem Ruby do eksportowania danych jako JSON, CSV, archiwum tabel CSV oraz PDF.
Nazwa i wersja `0.x` są robocze. Gem nie jest opublikowany; licencja i docelowy sposób
dystrybucji wymagają decyzji przed wydzieleniem repozytorium.

## Podłączenie

W aplikacji zawierającej ten katalog:

```ruby
gem "export_kit", path: "gems/export_kit"
```

Rdzeń nie bootuje Rails. Adapter modeli wymaga jawnego `require "export_kit/active_record"`
i Active Record dostarczonego przez aplikację.

## Prosty eksport

```ruby
require "export_kit"

result = ExportKit.render(
  { product: { sku: "LAMP-01", tags: ["vintage"] } },
  format: :json,
  max_bytes: 20 * 1024**2
)

if result.success?
  artifact = result.value!
  begin
    puts artifact.file.read
  ensure
    artifact.close!
  end
else
  warn result.error.to_s
end
```

`Result` ma `success?`, `failure?`, `error`, `error_details`, `value`, `value!`, `map`,
`map_error` i `and_then`. Oczekiwane odmowy zwracają kod, błędy programistyczne propagują
wyjątek po sprzątnięciu outputu. Szczegóły błędu wskazują znaną tabelę, wiersz i kolumnę,
bez wartości eksportowanych danych. Numer wiersza jest liczony od 1, bez nagłówka.

## Tabela

```ruby
table = ExportKit::Table.new(
  columns: %i[sku name],
  labels: { sku: "SKU", name: "Nazwa" },
  rows: [{ "sku" => "LAMP-01", "name" => "Lampa" }]
)

result = ExportKit.render(table, format: :csv, max_bytes: 20 * 1024**2)
# Odbiorca zamyka result.value!.close! po zakończeniu użycia.
```

`csv` daje pojedynczy CSV, `csv_zip` archiwum raportu. `Document` zachowuje sekcje i manifest.
Renderowanie zużywa źródło synchronicznie; jednorazowy enumerator należy odtworzyć przed
kolejnym wykonaniem. Raport PDF wymaga jawnego fontu Unicode. Limity zapisu nie gwarantują
ograniczonego RSS biblioteki PDF.

## Granice

Aplikacja wybiera autoryzowany zakres i zapewnia spójność odczytu. W bibliotece nie ma
użytkowników, policy scope, jobów, I18n, szyfrowania, storage ani retencji. Własny renderer jest
zaufanym kodem aplikacji. `Artifact#verify` i walidacja raportu nie dowodzą kompletności RODO.

Mieszane paczki plików są planowanym kolejnym etapem, nie istniejącym API.
Pełny przewodnik integracji w repo koncertowo: `docs/exports-architecture.md` i `docs/exports.md`.
