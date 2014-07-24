module db.userrule;

import std.string;
import std.algorithm;
import vibe.core.log;
import vibe.data.bson;
import db.envelope;
import retriever.incomingemail;
version(unittest)import std.stdio;


enum SizeRuleType
{
    GreaterThan,
    SmallerThan,
    None
}


struct Match
{
    bool withAttachment = false;
    bool withHtml       = false;
    string[string]   headerMatches;
    string[]         bodyMatches;
    SizeRuleType     totalSizeType = SizeRuleType.None;
    ulong            totalSizeValue;
}


struct Action
{
    bool noInbox      = false;
    bool markAsRead   = false;
    bool deleteIt     = false;
    bool neverSpam    = false;
    bool setSpam      = false;
    string[] addTags;
    string[] forwardTo;
}


class UserFilter
{
    package
    {
        Match match;
        Action action;
    }

    this(ref Match match, ref Action action)
    {
        this.match  = match;
        this.action = action;
    }


    void apply(ref Envelope envelope, ref bool[string] convTags) const
    {
        if (checkMatch(envelope)) 
            applyAction(envelope, convTags);
    }


    private bool checkMatch(ref Envelope envelope) const
    {
        if (this.match.withAttachment && !envelope.email.attachments.length)
            return false;

        if (this.match.withHtml)
        {
            bool hasHtml = false;
            foreach(const MIMEPart subpart; envelope.email.textualParts)
                if (subpart.ctype.name == "text/html")
                    hasHtml = true;
            if (!hasHtml)
                return false;
        }

        foreach(matchHeaderName, matchHeaderFilter; this.match.headerMatches)
            if (countUntil(envelope.email.getHeader(matchHeaderName).rawValue, matchHeaderFilter) == -1)
                return false;

        foreach(const MIMEPart part; envelope.email.textualParts)
        {
            foreach(string bodyMatch; this.match.bodyMatches)
                if (countUntil(part.textContent, bodyMatch) == -1)
                    return false;
        }

        if (this.match.totalSizeType != SizeRuleType.None)
        {
            auto emailSize = envelope.email.computeSize();
            if (this.match.totalSizeType == SizeRuleType.GreaterThan &&
                emailSize < this.match.totalSizeValue)
            {
                return false;
            }
            else if (this.match.totalSizeType == SizeRuleType.SmallerThan &&
                emailSize > this.match.totalSizeValue)
            {
                return false;
            }
        }
        return true;
    }


    private void applyAction(ref Envelope envelope, ref bool[string] convTags) const
    {
        // email.tags == false actually mean to the rest of the retriever processes: "it
        // doesnt have the tag and please dont add it after this point"
        if (this.action.noInbox)
            convTags["inbox"] = false;

        if (this.action.markAsRead) 
            convTags["unread"] = false;

        if (this.action.deleteIt)
            convTags["deleted"] = true;

        if (this.action.neverSpam)
            convTags["spam"] = false;

        if (this.action.setSpam)
            convTags["spam"] = true;

        foreach(string tag; this.action.addTags)
        {
            tag = toLower(tag);
            if (tag !in convTags)
                convTags[tag] = true;
        }

        if (this.action.forwardTo.length)
            envelope.forwardTo ~= this.action.forwardTo;
    }
}


