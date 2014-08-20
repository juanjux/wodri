module webbackend.apiemail;

struct ApiAttachment
{
    string Url;
    string ctype;
    string filename;
    string contentId;
    ulong  size;
}

final class ApiEmail
{
    string dbId;
    string messageId;
    string from; 
    string to; 
    string cc; 
    string bcc; 
    string subject; 
    string isoDate; 
    string date; 
    string bodyHtml;
    string bodyPlain;
    bool   deleted = false;
    bool   draft   = false;
    ApiAttachment[] attachments; 
}
