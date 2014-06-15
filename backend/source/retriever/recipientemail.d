module retriever.recipientemail;

import retriever.incomingemail: IncomingEmail;

// An incoming email represents an email, but it can go to different users
// managed by this system, so a RecipientEmail is the same (unique) email plus
// the receiving address and part that can change by every user (tags,
// doForwardTo). It has a similar document structure on the DB.
struct RecipientEmail
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

