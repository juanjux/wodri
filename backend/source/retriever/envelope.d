module retriever.envelope;

import retriever.incomingemail: IncomingEmail;

// An IncomingEmail object represents an email, but it can go to different users
// managed by this system, so an envelope has the same (unique) email plus the
// receiving address and a part that can change by every user.  It has a similar
// document structure on the DB.

struct Envelope
{
    const IncomingEmail email;
    string destination;
    string userId;
    string emailId;
    string[] forwardTo;
}
