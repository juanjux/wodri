module db.userfilter;

import std.string;
import std.algorithm;
import std.typecons;
import vibe.core.log;
import vibe.data.bson;
import db.config;
import db.email;
import db.tagcontainer;
import db.dbinterface.driveruserfilterinterface;
version(MongoDriver)
{
    import vibe.db.mongo.mongo;
    import db.mongo.mongo;
    import db.mongo.driveruserfiltermongo;
}
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


final class UserFilter
{
    package
    {
        Match match;
        Action action;
    }

    private
    {
        static DriverUserfilterInterface dbDriver = null;
    }

    static this()
    {
        version(MongoDriver)
            dbDriver = new DriverUserfilterMongo();
        enforce(dbDriver !is null, "You must select some DB driver!");
    }

    this(Match match, Action action)
    {
        this.match  = match;
        this.action = action;
    }


    void apply(Email email, ref string[] tagsToAdd, ref string[] tagsToRemove) const
    {
        if (checkMatch(email))
            applyAction(email, tagsToAdd, tagsToRemove);
    }


    private bool checkMatch(Email email) const
    {
        if (this.match.withAttachment && !email.attachments.length)
            return false;

        if (this.match.withHtml)
        {
            bool hasHtml = false;
            foreach(ref subpart; email.textParts)
            {
                if (subpart.ctype == "text/html")
                    hasHtml = true;
            }
            if (!hasHtml)
                return false;
        }

        foreach(matchHeaderName, matchHeaderFilter; this.match.headerMatches)
        {
            if (countUntil(email.getHeader(matchHeaderName).rawValue,
                           matchHeaderFilter) == -1)
                return false;
        }

        foreach(ref part; email.textParts)
        {
            foreach(string bodyMatch; this.match.bodyMatches)
                if (countUntil(part.content, bodyMatch) == -1)
                    return false;
        }

        if (this.match.totalSizeType != SizeRuleType.None)
        {
            immutable emailSize = email.size();
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


    private void applyAction(Email email, ref string[] tagsToAdd, ref string[] tagsToRemove)
    const
    {
        if (this.action.noInbox)
            tagsToRemove ~= "inbox";

        if (this.action.markAsRead)
            tagsToRemove ~= "unread";

        if (this.action.deleteIt)
            tagsToAdd ~= "deleted";

        if (this.action.neverSpam)
            tagsToRemove ~= "spam";

        if (this.action.setSpam)
            tagsToAdd ~= "spam";

        foreach(string tag; this.action.addTags)
            tagsToAdd ~= tag;

        if (this.action.forwardTo.length)
            email.forwardedTo ~= this.action.forwardTo;
    }


    // ==========================================================
    // Proxies for the dbDriver functions used outside this class
    // ==========================================================

    static UserFilter[] getByAddress(in string address)
    {
        return dbDriver.getByAddress(address);
    }
}
