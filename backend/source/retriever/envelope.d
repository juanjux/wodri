module retriever.envelope;

import retriever.incomingemail: IncomingEmail;
import std.string: format;
import std.conv: to;

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
    string dbId;

    string toJson()
    {
        return format(`
            {
                "_id": "%s",
                "emailId": "%s",
                "userId": "%s",
                "destinationAddress": "%s",
                "forwardTo": %s
            }`, 
            dbId, emailId, userId, destination, to!string(forwardTo)
        );
    }
}
