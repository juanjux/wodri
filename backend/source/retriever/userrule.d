module retriever.userrule;

import std.string;
import vibe.core.log;
import vibe.data.bson;
import retriever.envelope;
import retriever.incomingemail;


enum SizeRuleType
{
    GreaterThan,
    SmallerThan
}


struct Match
{
    bool withAttachment = false;
    bool withHtml       = false;
    bool withSizeLimit  = false;
    string[string]   headerMatches;
    string[]         bodyMatches;
    SizeRuleType     totalSizeType = SizeRuleType.GreaterThan;
    ulong            totalSizeValue;
}


struct Action
{
    bool noInbox      = false;
    bool markAsRead   = false;
    bool deleteIt     = false;
    bool neverSpam    = false;
    bool setSpam      = false;
    bool tagFavorite  = false;
    string[] addTags;
    string forwardTo;
}


class UserFilter
{
    Match match;
    Action action;

    this(ref Match match, ref Action action)
    {
        this.match  = match;
        this.action = action;
    }


    void apply(ref Envelope envelope)
    {
        if (checkMatch(envelope))
            applyAction(envelope);
    }

    bool checkMatch(ref Envelope envelope)
    {
        if (this.match.withAttachment && !envelope.email.attachments.length)
            return false;

        if (this.match.withHtml)
        {
            bool hasHtml = false;
            foreach(MIMEPart subpart; envelope.email.textualParts)
                if (subpart.ctype.name == "text/html")
                    hasHtml = true;
            if (!hasHtml)
                return false;
        }

        foreach(string matchHeaderName, string matchHeaderFilter; this.match.headerMatches)
            if (indexOf(envelope.email.getHeader(matchHeaderName).rawValue, matchHeaderFilter) == -1)
                return false;

        foreach(MIMEPart part; envelope.email.textualParts)
        {
            foreach(string bodyMatch; this.match.bodyMatches)
                if (indexOf(part.textContent, bodyMatch) == -1)
                    return false;
        }

        if (this.match.withSizeLimit)
        {
            auto emailSize = envelope.email.computeSize();
            if (this.match.totalSizeType == SizeRuleType.GreaterThan &&
                emailSize < this.match.totalSizeValue)
                return false;
            else if (this.match.totalSizeType == SizeRuleType.SmallerThan &&
                emailSize > this.match.totalSizeValue)
                return false;
        }
        return true;
    }


    void applyAction(ref Envelope envelope)
    {
        // email.tags == false actually mean to the rest of the retriever
        // processes: "it doesnt have the tag and please dont add it after this point"
        if (this.action.noInbox)
            envelope.tags["inbox"] = false;

        if (this.action.markAsRead)
            envelope.tags["unread"] = false;

        if (this.action.deleteIt)
            envelope.tags["deleted"] = true;

        if (this.action.neverSpam)
            envelope.tags["spam"] = false;

        if (this.action.setSpam)
            envelope.tags["spam"] = true;

        if (this.action.tagFavorite)
            envelope.tags["favorite"] = true;

        foreach(string tag; this.action.addTags)
        {
            tag = toLower(tag);
            if (tag !in envelope.tags)
                envelope.tags[tag] = true;
        }

        if (this.action.forwardTo.length)
            envelope.forwardTo ~= this.action.forwardTo;
    }
}


