# Pas2Dox Modern 0.60.0-rc4

Önálló Windows x64 Doxygen-filter Delphi-forrásokhoz, statikusan feloldható
hívó (caller) és hívott (call) gráfok támogatásával.

## A projekt tartalma

```text
source/
  pas2dox.dpr, Dox_*.pas    A szűrő forrása
  pasdoc/                  A fordításhoz szükséges Pascal-elemző forrása és licence
build.cmd                  A fordítás indítója
build.ps1                  A fordítás parancsai
build/
  pas2dox.exe              A kész szűrőprogram
README.md                  Ez az útmutató
LICENSE                    GPL v2 licenc
examples/                  Nyilvános példaprojekt és Doxyfile
tests/                     Megismételhető, szintetikus tesztek
docs/                      Támogatási és kiadási útmutatók
```

A forrás és a futtatható program verziója egyaránt `0.60.0-rc4`.
A nyilvános kiadás példái az `examples`, tesztjei a `tests` mappában találhatók.
A részletes kiadási és közreműködési útmutató angolul érhető el.

A tesztek futtatása: `python -X utf8 tests\run_tests.py`. A példa:
`doxygen examples\Doxyfile`. A tesztekhez Python, Doxygen és Graphviz kell.

## Fordítás

Windows és telepített Delphi Win64 fordító/RTL szükséges. A fordítás Delphi 11
`dcc64.exe` fordítóval ellenőrzött. A projekt könyvtárában:

```powershell
.\build.cmd
```

A parancs először a PATH-on keresi a `dcc64.exe` fájlt, majd a Delphi 11 szokásos
telepítési helyén. Más telepítés esetén:

```powershell
.\build.cmd -Compiler "C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc64.exe"
```

Az eredmény a `build\pas2dox.exe`. A köztes fordítási állományok ideiglenes
mappában készülnek, amelyet a parancs a végén eltávolít. A korábbi EXE-t csak
sikeres fordítás, verzió- és másolatellenőrzés után cseréli le. Python nem kell.

Verzióellenőrzés:

```powershell
.\build\pas2dox.exe --version
```

## Használat Doxygen-filterként

A futtatáshoz a kész EXE, Doxygen és a gráfokhoz Graphviz szükséges. Példa
Delphi 11, Win32 alkalmazáshoz:

```ini
INPUT_ENCODING      = UTF-8
INPUT_FILTER        = "C:\Tools\pas2dox-modern\build\pas2dox.exe --delphi=11 --platform=win32"
FILTER_PATTERNS     =
FILTER_SOURCE_FILES = YES
EXTENSION_MAPPING  = pas=C++ PAS=C++ dpr=C++ DPR=C++
HAVE_DOT            = YES
CALL_GRAPH          = YES
CALLER_GRAPH        = YES
GENERATE_HTML       = YES
GENERATE_LATEX      = YES
```

A projekt meglévő `INPUT`, `FILE_PATTERNS`, `RECURSIVE` és kizárási beállításai
választják ki a dokumentált forrásokat. A Doxygent a megszokott módon indítsd;
a PDF a generált LaTeX szokásos fordításával készíthető el.

A szűrő kimenete UTF-8. Régi, BOM nélküli Windows-1250 forrásnál az EXE
argumentumaihoz `--encoding=1250` adható; a Doxygen `INPUT_ENCODING` értéke
ekkor is UTF-8. A `--delphi`, `--platform` és ismételhető `-DNAME` kapcsolókat
a dokumentált alkalmazás konfigurációjához igazítsd. Az EXE Win64 volta nem
határozza meg a dokumentált alkalmazás platformját. További kapcsolók:

```powershell
.\build\pas2dox.exe --help
```

## Delphi TODO-bejegyzések

A szabványos Delphi TODO-kommenteket a szűrő automatikusan Doxygen `\todo`
bejegyzéssé alakítja. Példák a támogatott alakokra:

```pascal
// TODO: Hibakezelés kiegészítése.
{ TODO 1 -oAlex -cUI : A párbeszédablak javítása. }
(* TODO: Többsoros megjegyzés is használható. *)
```

A prioritás, felelős és kategória szövege megmarad, a bejegyzés kiegészül az
eredeti fájlnévvel és sorszámmal. A rutintörzsben található feladat a rutin
leírásához kapcsolódik; az egyéb forráshelyek az unithoz. Az inicializálási,
finalizálási és programtörzsben lévő, valamint a záró pont utáni feladatok is
megjelennek. Az include fájlban lévő TODO megőrzi az include fájl forráshelyét.

A fájl fejlécében írt `@todo` fájlszintű feladat, a rutintörzsben lévő
`// TODO:` pedig az adott rutinhoz kapcsolódik. Mindkettő megjelenik az
összesített TODO-listában.

A `@todo No general To-Do` kézzel beírt sablonszöveg: a Doxygen ezt is
teendőként veszi át, nem ellenőrzi a mondat jelentését. Ha nincs fájlszintű
feladat, hagyd el ezt a sort, vagy használj egyszerű megjegyzést:

```pascal
/// @note Nincs általános, fájlszintű teendő.
```

Az `@bug No known bugs` és `@deprecated No deprecated functions` hasonlóan
félrevezető listabejegyzést hoz létre. Ezeket a jelöléseket konkrét hibához,
illetve ténylegesen elavult elemhez használd; az üres sablonsorokat hagyd el.

A Doxygen összesített TODO-listájához:

```ini
GENERATE_TODOLIST = YES
```

A lista HTML-ben és LaTeX/PDF-kimenetben is elérhető. Az inaktív feltételes
ágak és sztringliterálok TODO-szövege nem válik teendővé. A `-i` használatakor
csak az interface TODO-bejegyzései kerülnek át. Az eredeti `@todo`/`\todo`
dokumentációs jelölések megmaradnak.

Hivatalos leírások: [Delphi To-Do lista](https://docwiki.embarcadero.com/RADStudio/Athens/en/To-Do_List)
és [Doxygen todo parancs](https://www.doxygen.nl/manual/commands.html#cmdtodo).

## A gráfok értelmezése és korlátai

A `FILTER_SOURCE_FILES = YES` a gráfokhoz is kell. A `-i` csak az interface-t
olvassa, ezért hívási gráfokhoz hagyd el. A `--no-call-graph` deklarációs
dokumentációt készít automatikus hívásfeloldás nélkül.

A szűrő a forrás mappájában és közeli projektgyökerében megtalált unitok
interface-eiből keresi az objektumok, mezők, propertyk és öröklés típusait.
Az egyértelmű célokat adja át; a bizonytalan overloadok, ismeretlen külső
objektumok, dinamikus callback-hivatkozások és `with` miatt bizonytalan nevek
kimaradnak. Az overloadok `__overload_...` gráfazonosítót kaphatnak; az eredeti
Delphi-deklaráció a leírásban megmarad.

A paraméter nélküli anonim eljárások híváshelyei a tartalmazó rutin gráfján
szerepelnek, külön megjegyzéssel. Ez nem bizonyítja a callback végrehajtását.
A paraméteres/saját lokális változós anonim és névvel deklarált beágyazott
rutinok, valamint a puszta `inherited;` hívás még nincsenek teljesen modellezve.
A gráf forráskapcsolatot mutat, nem teljes futási hívásnyomot.

A modern nyelvi támogatás tényleges fordítós ellenőrzése Delphi 11-gyel történt;
Delphi 12/13/13.2 fordítóval még nincs teljes megfelelőségi igazolás. A PUSHOPT
részhalmaz alak nem támogatott; a teljes PUSHOPT/POPOPT igen. A `.dproj`
konfigurációt és a `.dpk` package-manifesztet nem importálja automatikusan.

## Licenc

A saját szűrő GPL v2 licencű. A beépített, módosított PasDoc források eredeti
GPL-2.0-or-later licence és eredetleírása a `source\pasdoc` mappában található.
