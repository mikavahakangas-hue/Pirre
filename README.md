# Pirre – NSPIRE UI päivityskanava

Tämä julkinen repository toimii Raspberry Pi Zero 2 W -pohjaisen Pirre/NSPIRE-käyttöliittymän päivityskanavana.

## Päivitysmanifesti

Raspberry Pi tarkistaa uusimman version tiedostosta:

`https://raw.githubusercontent.com/mikavahakangas-hue/Pirre/main/update-manifest.json`

Päivityspaketit tallennetaan `releases/`-kansioon. Laite hyväksyy paketin vain, kun manifestin versio, latausosoite ja SHA-256-tarkistussumma ovat kelvollisia.

## Tietoturva

Repositoryyn ei saa lisätä API-avaimia, Wi-Fi-salasanoja, Google-kalenterien salaisia iCal-osoitteita, keskusteluhistoriaa, henkilötietoja tai laitteen paikallisia asetustiedostoja.
