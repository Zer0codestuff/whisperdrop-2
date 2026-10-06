#!/usr/bin/env python3
"""Create synthetic Italian sources for local context comparisons. No user library is read."""
import argparse
import json
from pathlib import Path

TOPICS = [
    ("integrità dei dati", "Una copia utile deve conservare il contenuto e permettere di verificarlo. Il controllo viene eseguito prima di considerare concluso il trasferimento. Un nome corretto non dimostra che tutti i dati siano stati copiati."),
    ("transazioni", "Le modifiche collegate devono diventare visibili insieme. Se una parte non può essere completata, il sistema conserva lo stato precedente. La registrazione degli eventi permette di capire quali operazioni siano state confermate."),
    ("indici", "Un indice rende più rapide alcune ricerche ma richiede spazio e lavoro quando i dati cambiano. La scelta dipende dalle richieste effettive. Non serve indicizzare ogni campo senza verificare il costo delle modifiche."),
    ("concorrenza", "Due operazioni possono leggere lo stesso dato prima che una delle due lo aggiorni. Occorre stabilire quale modifica abbia precedenza. Un risultato ottenuto da una vecchia lettura non deve sostituire automaticamente uno più recente."),
    ("accessibilità", "Un comando deve avere un nome comprensibile anche senza vedere la sua icona. L'ordine dei controlli deve seguire il percorso di lavoro. La tastiera deve permettere di raggiungere le stesse funzioni offerte dal puntatore."),
    ("memoria", "Il consumo dipende dai dati presenti e dalle operazioni in corso. Un limite utile lascia spazio anche al sistema operativo. Le misure vanno ripetute con lo stesso carico e devono distinguere i dati residenti dalle semplici prenotazioni."),
    ("registrazioni", "La raccolta dei campioni deve rispettare l'ordine originale. Una coda troppo piccola può perdere dati durante un rallentamento. La chiusura attende che i campioni già ricevuti siano stati scritti e segnala eventuali errori."),
    ("formati", "Il formato di un file descrive come leggere i dati, non soltanto la sua estensione. Due file con nomi simili possono richiedere lettori diversi. Le verifiche devono controllare anche i valori necessari per interpretare il contenuto."),
    ("backup", "Una copia nello stesso disco aiuta contro alcuni errori ma non contro la perdita del dispositivo. Il ripristino deve essere provato. È necessario sapere quali file appartengano alla copia e quale versione dei dati rappresentino."),
    ("interfacce", "I comandi frequenti devono essere visibili nel punto in cui vengono usati. Cambiare sezione non dovrebbe cancellare un lavoro incompleto. Il contesto aiuta a distinguere il documento originale da una proposta ancora da approvare."),
    ("reti", "Una richiesta può fallire anche dopo che il destinatario ha eseguito l'operazione. Ripetere una modifica senza controllare lo stato può creare duplicati. La risposta deve indicare ciò che è stato confermato e ciò che rimane incerto."),
    ("test", "Un controllo utile verifica una proprietà del risultato. La sola assenza di errori non dimostra che il contenuto sia corretto. I casi di prova devono includere anche interruzioni, dati mancanti e condizioni vicine ai limiti."),
    ("sicurezza", "Ogni componente dovrebbe ricevere soltanto gli accessi necessari al proprio compito. Una funzione locale non deve aprire un servizio a tutta la rete. Le credenziali temporanee vengono escluse dai file che saranno distribuiti."),
    ("versioni", "Il documento originale permette di valutare le modifiche successive. Una nuova versione descrive chi o cosa abbia prodotto il risultato e quando. Le annotazioni aggiuntive devono restare leggibili senza alterare i riferimenti del documento."),
    ("tempi", "Un sistema rapido in un caso breve può diventare lento quando aumenta il lavoro. Il tempo di preparazione va distinto da quello dell'operazione principale. Le misure devono riportare la quantità di dati effettivamente elaborata."),
    ("errori", "Un messaggio utile indica quale operazione non sia riuscita e quale risultato sia ancora disponibile. Non deve dichiarare un successo che non è stato verificato. Conservare il lavoro precedente permette di riprovare senza ricostruirlo."),
]
EXERCISES = [
    "La prova parte da un archivio piccolo e aggiunge nuovi elementi prima di ripetere il controllo.",
    "L'esercizio confronta una procedura manuale con una procedura automatica e annota i risultati diversi.",
    "Il gruppo interrompe il lavoro a metà e controlla quali informazioni siano ancora disponibili.",
    "La dimostrazione presenta prima il caso normale e poi un caso con un dato mancante.",
    "La discussione confronta due configurazioni mantenendo uguali gli altri parametri della prova.",
    "Il laboratorio usa una copia dei materiali, così l'esperimento non modifica l'archivio originale.",
    "Ogni partecipante legge il risultato e controlla se corrisponde alla richiesta iniziale.",
    "Il docente separa le osservazioni misurate dalle ipotesi che richiedono un'altra prova.",
]


def paragraphs(count):
    result = []
    for index in range(count):
        topic, explanation = TOPICS[index % len(TOPICS)]
        result.append(f"Sezione {index + 1}. Nel laboratorio di {topic} si esamina il comportamento di un sistema usato per archiviare materiali didattici. "
                      f"{explanation} {EXERCISES[index % len(EXERCISES)]} "
                      "Prima di passare alla sezione successiva, vengono conservati gli appunti dell'esercizio e viene descritta la differenza tra il risultato atteso e quello osservato. Queste osservazioni tecniche non cambiano le decisioni del progetto Aurora.")
    return result


def lecture(count):
    beginning = ("Verbale del progetto Aurora. Giulia Neri coordina il progetto e Marco Serra verifica i testi. "
                 "La prima proposta prevede un budget provvisorio di 8000 euro e un lancio il 20 ottobre. "
                 "Questi valori sono ancora da approvare. La riunione continua con una lunga lezione sui sistemi informatici.")
    ending = ("Decisioni finali approvate del progetto Aurora. La proposta iniziale viene sostituita: il budget definitivo è di 12000 euro "
              "e il lancio è fissato al 27 ottobre. Restano valide le responsabilità assegnate all'inizio del verbale. "
              "La newsletter è esclusa da questa fase. Le decisioni finali sostituiscono tutte le date e i budget provvisori discussi prima.")
    return "\n\n".join([beginning, *paragraphs(count), ending])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    summary_instruction = ("Riassumi soltanto le decisioni finali del progetto Aurora. Includi il budget definitivo, "
                           "la data del lancio, i due responsabili con i loro compiti e la decisione sulla newsletter. "
                           "Escludi i valori provvisori e la lezione tecnica. Scrivi in italiano.")
    required = [r"12[., ]?000", r"27\s+ottobre", r"Giulia", r"Marco", r"newsletter"]
    forbidden = [r"8[., ]?000", r"20\s+ottobre"]
    common = ["8k", "16k", "32k", "automatic"]
    long_edit = "\n\n".join(["Appunti da correggere. Il riferimento iniziale è ALFA-418.", *paragraphs(24), "Fine degli appunti. Il riferimento conclusivo è ARCO-731."])
    fixtures = [
        dict(id="long-summary", action="summary", text=lecture(64), instruction=summary_instruction,
             profiles=common, requiredPatterns=required, forbiddenPatterns=forbidden),
        dict(id="extended-summary", action="summary", text=lecture(128), instruction=summary_instruction,
             profiles=["32k", "automatic", "automatic-16gb"], requiredPatterns=required, forbiddenPatterns=forbidden),
        dict(id="english-grammar", action="grammar", text="She don't have time today.", instruction="",
             profiles=common, requiredPatterns=[r"doesn't|does not"], forbiddenPatterns=[r"don't"]),
        dict(id="italian-grammar", action="grammar", text="Ieri abbiamo ricevuto i documenti e lo abbiamo controllati. La consegna resta fissata per venerdì.", instruction="",
             profiles=common, requiredPatterns=[r"li abbiamo controllati", r"venerdì"], forbiddenPatterns=[r"lo abbiamo controllati"]),
        dict(id="long-edit", action="grammar", text=long_edit, instruction="Conserva ogni paragrafo e tutti i riferimenti. Correggi soltanto gli errori di grammatica.",
             profiles=["8k", "automatic"], requiredPatterns=[r"ALFA-418", r"ARCO-731", r"Sezione 24"], forbiddenPatterns=[]),
    ]
    (args.output / "fixtures.json").write_text(json.dumps(fixtures, ensure_ascii=False, indent=2) + "\n")
    for fixture in fixtures:
        (args.output / (fixture["id"] + ".txt")).write_text(fixture["text"] + "\n")
        print(f"{fixture['id']}: {len(fixture['text'].split())} words")


if __name__ == "__main__":
    main()
