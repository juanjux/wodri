module retriever.envelope;

import retriever.incomingemail: IncomingEmail;

// An IncomingEmail object represents an email, but it can go to different users
// managed by this system, so an envelope has the same (unique) email plus
// the receiving address and a part that can change by every user (tags,
// doForwardTo). It has a similar document structure on the DB.

struct Envelope 
{
    IncomingEmail email;
    bool[string] tags;
    string[] doForwardTo;
    string destination;

    this(IncomingEmail email, string destination)
    {
        this.email = email;
        this.destination = destination;
    }
}

