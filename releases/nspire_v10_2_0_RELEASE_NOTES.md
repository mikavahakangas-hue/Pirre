# NSPIRE V10.2.0 Permanent Remote & Clear UI

## Käyttöliittymä

- Nykyisen etusivun painikkeiden ja kansioiden määrä säilytetään muuttumattomana.
- Valikkojen rakennetta ja näkymien luettavuutta selkeytetään ilman sovellusten poistamista.
- Asetukset, verkko, huolto ja Companion ryhmitellään selkeämmin.
- Yläpalkkia kevennetään ja lämpötila siirretään laitteen kuntotietoihin.
- Vieritettävissä näkymissä säilyvät yleiset vierityspainikkeet.

## Teemapaketit

Oletusteema on **Karelia Orange**.

Mukana ovat:

- Karelia Orange
- Graphite
- Industrial Amber
- Forest
- Midnight
- Monochrome
- High Contrast
- Light Workshop

Teema-asetuksiin kuuluvat tekstikoko, kulmien pyöreys, reunukset ja varjot. Laitteen ja Companionin teema voidaan vaihtaa ilman käyttöjärjestelmän uudelleenkäynnistystä. Merkitysvärit vihreä, keltainen ja punainen säilyvät tilailmaisuina.

## Permanent Remote Companion

- Pysyvä 8-numeroinen pääsykoodi luodaan vain ensimmäisellä asennuksella.
- Pääsykoodi ei vanhene eikä vaihdu uudelleenkäynnistyksissä tai päivityksissä.
- Käyttäjä voi vaihtaa koodin 8–16-numeroiseksi.
- Hyväksytyt puhelimet saavat pitkäikäisen laitetunnisteen, joka voidaan perua laitekohtaisesti.
- Kaikki puhelimet voidaan kirjata ulos yhdellä toiminnolla.
- Väärät kirjautumisyritykset aiheuttavat asteittaisen viiveen.
- Etäohjaus voidaan estää mittareita ja diagnostiikkaa sammuttamatta.
- Mukana ovat etäleikepöytä, tiedoston lähetys, aktiivisen sovelluksen ohjaus ja etätoimintoloki.
- Tailscale-, Wi-Fi- ja reititinasetuksia ei muuteta.

## Black Box

- SQLite WAL, 30 sekunnin mittausväli ja eräkirjoitus.
- Viimeisten 24 tunnin CPU-, lämpötila-, RAM-, swap-, akku-, levy-, UI-muisti-, vaste- ja palvelutiedot.
- Automaattinen ongelma-analyysi ja lukittava `Laite tahmaa nyt` -tilannekuva.
- Black Box ei käynnistä palveluita uudelleen.

## Asennusturvallisuus

- Nykyinen V10/V10.1 varmuuskopioidaan ennen muutoksia.
- Python-, JavaScript-, manifesti- ja Bash-tarkistukset tehdään ennen aktivointia.
- Uusi Companion testataan väliaikaisessa portissa ennen vanhan palvelun vaihtamista.
- Etusivun sovellus- ja kansiomäärä tarkistetaan ennen ja jälkeen muutoksen.
- Asennus palauttaa aiemman version, jos lopputarkistus epäonnistuu.
- Palautuskomento on `sudo nspire-v102-rollback`.

Fyysisen Raspberry Pi Zero 2 W:n, Waveshare-näytön ja nykyisen kioskikäynnistyksen lopullinen yhteensopivuus varmistuu ensimmäisessä laiteasennuksessa.
