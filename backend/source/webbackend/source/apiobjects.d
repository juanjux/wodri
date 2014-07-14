import std.algorithm;
import std.conv;
import vibe.web.common;
import retriever.db;

struct Attachment
{
    string Url;
    string ctype;
    string filename;
    string contentId;
    ulong size;
}

@rootPathFromName
interface Api
{
    string[] getTag(string name = "inbox", uint limit = 50);
}


class ApiImpl: Api
{
    override:
        string[] getTag(string name = "inbox", uint limit = 50)
        {
            return [name, to!string(limit), "uno", "dos", "tres"];
        }
}


struct MessageSummary
{
    string subject;
    string from;
    string date;
    string[] attachmentsFilenames;
    string bodyPeak;
    string avatarUrl;
}

struct Message
{
    MessageSummary apiMessageSummary;
    alias apiMessageSummary this;
    string bodyHtml;
    string bodyPlain;
    Attachment[] attachments;
}

struct Conversation
{
    MessageSummary[] summaries;
    string lastMessageDate;
    string subject;
    string[] tags;
    string[] attachmentsFilenames;

    this(string subject, string[] tags, ref MessageSummary[] summaries)
    {
        this.summaries = summaries;

        foreach(msgSummary; summaries)
        {
            this.lastMessageDate = max(this.lastMessageDate, msgSummary.date);
            attachmentsFilenames ~= msgSummary.attachmentsFilenames;
        }
    }
}

