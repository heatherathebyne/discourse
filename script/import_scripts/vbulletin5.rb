# frozen_string_literal: true

require 'mysql2'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")
require 'htmlentities'

class ImportScripts::VBulletin < ImportScripts::Base
  BATCH_SIZE = 1000
  ATTACHMENT_BATCH_SIZE = 50 # chonky queries
  ROOT_NODE = 2
  BANNED_USERS_GROUP = 8
  TIMEZONE = "America/Los_Angeles"

  # override these using environment vars

  URL_PREFIX ||= ENV['URL_PREFIX'] || "forum/"
  DB_PREFIX ||= ENV['DB_PREFIX'] || "vb_"
  DB_HOST ||= ENV['DB_HOST'] || "localhost"
  DB_NAME ||= ENV['DB_NAME'] || "vbulletin"
  DB_PASS ||= ENV['DB_PASS'] || "password"
  DB_USER ||= ENV['DB_USER'] || "username"
  ATTACH_DIR ||= ENV['ATTACH_DIR'] || "/home/discourse/vbulletin/attach"
  AVATAR_DIR ||= ENV['AVATAR_DIR'] || "/home/discourse/vbulletin/avatars"
  # Nodes specified here will be imported the same way as the main forums;
  # that is, their child category (channel) nodes will be imported as top level categories,
  # and grandchild nodes will be imported as subcategories.
  # Provide a comma-delimited list.
  # example: EXTRA_ROOT_NODES=5 or EXTRA_ROOT_NODES=5,47
  EXTRA_ROOT_NODES ||= ENV['EXTRA_ROOT_NODES'] || ""
  # Channel nodes specified here will be imported directly as categories,
  # and child channel nodes as subcategories.
  # This is useful if you don't want to import all of the parent node's children.
  # Also takes a comma-delimited list:
  # EXTRA_CAT_NODES=4 or EXTRA_CAT_NODES=4,23
  EXTRA_CAT_NODES ||= ENV['EXTRA_CAT_NODES'] || ""

  def initialize
    super

    @old_username_to_new_usernames = {}

    @tz = TZInfo::Timezone.get(TIMEZONE)

    @htmlentities = HTMLEntities.new

    @client = Mysql2::Client.new(
      host: DB_HOST,
      username: DB_USER,
      database: DB_NAME,
      password: DB_PASS
    )

    @forum_typeid = mysql_query("SELECT contenttypeid FROM #{DB_PREFIX}contenttype WHERE class='Forum'").first['contenttypeid']
    @channel_typeid = mysql_query("SELECT contenttypeid FROM #{DB_PREFIX}contenttype WHERE class='Channel'").first['contenttypeid']
    @text_typeid = mysql_query("SELECT contenttypeid FROM #{DB_PREFIX}contenttype WHERE class='Text'").first['contenttypeid']
    # gallery posts are often side by side with text posts in topics
    @gallery_typeid = mysql_query("SELECT contenttypeid FROM #{DB_PREFIX}contenttype WHERE class='Gallery'").first['contenttypeid']
    @post_typeids = [@text_typeid, @gallery_typeid]
    @post_typeids_string = @post_typeids.join(',')
  end

  def execute
    import_groups
    import_users
    import_categories
    import_topics
    import_posts
    import_attachments
    import_tags
    close_topics
    post_process_posts
    create_permalinks
  end

  def import_groups
    puts "", "importing groups..."

    groups = mysql_query <<-SQL
        SELECT usergroupid, title
          FROM #{DB_PREFIX}usergroup
      ORDER BY usergroupid
    SQL

    create_groups(groups) do |group|
      {
        id: group["usergroupid"],
        name: @htmlentities.decode(group["title"]).strip
      }
    end
  end

  def import_users
    puts "", "importing users"

    user_count = mysql_query("SELECT COUNT(userid) count FROM #{DB_PREFIX}user").first["count"]

    batches(BATCH_SIZE) do |offset|
      users = mysql_query <<-SQL
          SELECT u.userid, u.username, u.homepage, u.usertitle, u.usergroupid, u.membergroupids, u.joindate, u.email, ub.bandate, ub.liftdate, ub.reason,
            CASE WHEN u.scheme='blowfish:10' THEN token
                 WHEN u.scheme='legacy' THEN REPLACE(token, ' ', ':')
            END AS password,
            IF(ug.title = 'Administrators', 1, 0) AS admin
            FROM #{DB_PREFIX}user u
            LEFT JOIN #{DB_PREFIX}usergroup ug ON ug.usergroupid = u.usergroupid
            LEFT JOIN #{DB_PREFIX}userban ub ON ub.userid = u.userid
        ORDER BY userid
           LIMIT #{BATCH_SIZE}
          OFFSET #{offset}
      SQL

      break if users.size < 1

      # disabled line below, caused issues
      # next if all_records_exist? :users, users.map {|u| u["userid"].to_i}

      create_users(users, total: user_count, offset: offset) do |user|
        username = @htmlentities.decode(user["username"]).strip
        {
          id: user["userid"],
          name: username,
          username: username,
          email: user["email"].presence || fake_email,
          admin: user['admin'] == 1,
          password: user["password"],
          website: user["homepage"].strip,
          title: @htmlentities.decode(user["usertitle"]).strip,
          primary_group_id: group_id_from_imported_group_id(user["usergroupid"]),
          created_at: parse_timestamp(user["joindate"]),
          post_create_action: proc do |u|
            @old_username_to_new_usernames[user["username"]] = u.username
            import_profile_picture(user, u)
            # import_profile_background(user, u)

            all_user_groups = [user['usergroupid'], user['membergroupids'].split(',')].flatten

            all_user_groups.each { |id| Group.find(group_id_from_imported_group_id(id)).add(u) }

            # suspend users in the Banned Users group
            if all_user_groups.include?(BANNED_USERS_GROUP)
              suspended_at = (user['bandate'] && user['bandate'] != 0) ? Time.at(user['bandate']) : Time.current
              suspended_till = (user['liftdate'] && user['liftdate'] != 0) ? Time.at(user['liftdate']) : Time.current + 1000.years

              u.update(suspended_at: suspended_at, suspended_till: suspended_till)
            end
          end
        }
      end
    end
  end

  def import_profile_picture(old_user, imported_user)
    query = mysql_query <<-SQL
        SELECT filedata, filename
          FROM #{DB_PREFIX}customavatar
         WHERE userid = #{old_user["userid"]}
      ORDER BY dateline DESC
         LIMIT 1
    SQL

    picture = query.first

    return if picture.nil?

    if picture['filedata']
      file = Tempfile.new("profile-picture")
      file.write(picture["filedata"].encode("ASCII-8BIT").force_encoding("UTF-8"))
      file.rewind
      upload = UploadCreator.new(file, picture["filename"]).create_for(imported_user.id)
    else
      filename = File.join(AVATAR_DIR, picture['filename'])
      unless File.exist?(filename)
        puts "Avatar file doesn't exist: #{filename}"
        return nil
      end
      upload = create_upload(imported_user.id, filename, picture['filename'])
    end

    return if !upload.persisted?

    imported_user.create_user_avatar
    imported_user.user_avatar.update(custom_upload_id: upload.id)
    imported_user.update(uploaded_avatar_id: upload.id)
  ensure
    file.close rescue nil
    file.unlink rescue nil
  end

  def import_profile_background(old_user, imported_user)
    query = mysql_query <<-SQL
        SELECT filedata, filename
          FROM #{DB_PREFIX}customprofilepic
         WHERE userid = #{old_user["userid"]}
      ORDER BY dateline DESC
         LIMIT 1
    SQL

    background = query.first

    return if background.nil?

    file = Tempfile.new("profile-background")
    file.write(background["filedata"].encode("ASCII-8BIT").force_encoding("UTF-8"))
    file.rewind

    upload = UploadCreator.new(file, background["filename"]).create_for(imported_user.id)

    return if !upload.persisted?

    imported_user.user_profile.upload_profile_background(upload)
  ensure
    file.close rescue nil
    file.unlink rescue nil
  end

  def import_categories
    puts "", "importing top level categories..."

    extra_root_node_ids = EXTRA_ROOT_NODES.split(',').map(&:to_i)
    all_root_node_ids = [ROOT_NODE, extra_root_node_ids].flatten
    extra_root_node_ids_string = extra_root_node_ids.join(',')
    all_root_node_ids_string = all_root_node_ids.join(',')

    extra_cat_node_ids = EXTRA_CAT_NODES.split(',').map(&:to_i)
    extra_cat_node_ids_string = extra_cat_node_ids.join(',')

    categories = mysql_query("SELECT nodeid AS forumid, title, description, displayorder, parentid
        FROM #{DB_PREFIX}node
          WHERE parentid IN (#{all_root_node_ids_string})
          OR nodeid IN (#{extra_cat_node_ids_string})
        UNION
          SELECT nodeid, title, description, displayorder, parentid
          FROM #{DB_PREFIX}node
          WHERE contenttypeid = #{@channel_typeid}
            AND parentid IN (SELECT nodeid FROM #{DB_PREFIX}node WHERE parentid IN (#{all_root_node_ids_string}) OR nodeid IN (#{extra_cat_node_ids_string}))").to_a

    top_level_categories = categories.select { |c| all_root_node_ids.include?(c["parentid"]) || extra_cat_node_ids.include?(c['forumid']) }

    create_categories(top_level_categories) do |category|
      {
        id: category["forumid"],
        name: @htmlentities.decode(category["title"]).strip,
        position: category["displayorder"],
        description: @htmlentities.decode(category["description"]).strip
      }
    end

    puts "", "importing child categories..."

    top_level_category_ids = Set.new(top_level_categories.map { |c| c["forumid"] })
    children_categories = categories.select { |c| !all_root_node_ids.include?(c["parentid"]) && !extra_cat_node_ids.include?(c['forumid']) && !top_level_category_ids.include?(c['forumid'])}

    # cut down the tree to only 2 levels of categories
    children_categories.each do |cc|
      while !top_level_category_ids.include?(cc["parentid"]) && !extra_cat_node_ids.include?(cc['parentid'])
        cc["parentid"] = categories.detect(-> { raise "no top_level_category_id found for nodeid #{cc['forumid']}" }) { |c| c["forumid"] == cc["parentid"] }["parentid"]
      end
    end

    create_categories(children_categories) do |category|
      {
        id: category["forumid"],
        name: @htmlentities.decode(category["title"]).strip,
        position: category["displayorder"],
        description: @htmlentities.decode(category["description"]).strip,
        parent_category_id: category_id_from_imported_category_id(category["parentid"])
      }
    end
  end

  def import_topics
    puts "", "importing topics..."

    # keep track of closed topics
    @closed_topic_ids = []

    topic_count = mysql_query("SELECT COUNT(nodeid) cnt
        FROM #{DB_PREFIX}node
        WHERE (unpublishdate = 0 OR unpublishdate IS NULL)
        AND (approved = 1 AND showapproved = 1)
        AND parentid IN (
        SELECT nodeid FROM #{DB_PREFIX}node WHERE contenttypeid=#{@channel_typeid} ) AND contenttypeid IN (#{@post_typeids_string});"
    ).first["cnt"]

    batches(BATCH_SIZE) do |offset|
      topics = mysql_query <<-SQL
        SELECT t.nodeid AS threadid, t.title, t.parentid AS forumid,t.open,t.userid AS postuserid,t.publishdate AS dateline,
            nv.count views, 1 AS visible, t.sticky,
            CONVERT(CAST(rawtext AS BINARY)USING utf8) AS raw
        FROM #{DB_PREFIX}node t
        LEFT JOIN #{DB_PREFIX}nodeview nv ON nv.nodeid=t.nodeid
        LEFT JOIN #{DB_PREFIX}text txt ON txt.nodeid=t.nodeid
        WHERE t.parentid in ( select nodeid from #{DB_PREFIX}node where contenttypeid=#{@channel_typeid} )
          AND t.contenttypeid IN (#{@post_typeids_string})
          AND (t.unpublishdate = 0 OR t.unpublishdate IS NULL)
          AND t.approved = 1 AND t.showapproved = 1
        ORDER BY t.nodeid
           LIMIT #{BATCH_SIZE}
          OFFSET #{offset}
      SQL

      break if topics.size < 1

      # disabled line below, caused issues
      # next if all_records_exist? :posts, topics.map {|t| "thread-#{topic["threadid"]}" }

      create_posts(topics, total: topic_count, offset: offset) do |topic|
        raw = preprocess_post_raw(topic["raw"]) rescue nil
        next if raw.blank?
        topic_id = "thread-#{topic["threadid"]}"
        @closed_topic_ids << topic_id if topic["open"] == "0"
        t = {
          id: topic_id,
          user_id: user_id_from_imported_user_id(topic["postuserid"]) || Discourse::SYSTEM_USER_ID,
          title: @htmlentities.decode(topic["title"]).strip[0...255],
          category: category_id_from_imported_category_id(topic["forumid"]),
          raw: raw,
          created_at: parse_timestamp(topic["dateline"]),
          visible: topic["visible"].to_i == 1,
          views: topic["views"],
        }
        t[:pinned_at] = t[:created_at] if topic["sticky"].to_i == 1
        t
      end
    end
  end

  def import_posts
    puts "", "importing posts..."

    # make sure `firstpostid` is indexed
    begin
      mysql_query("CREATE INDEX firstpostid_index ON thread (firstpostid)")
    rescue
    end

    post_count = mysql_query("SELECT COUNT(nodeid) cnt FROM #{DB_PREFIX}node WHERE parentid NOT IN (
        SELECT nodeid FROM #{DB_PREFIX}node WHERE contenttypeid=#{@channel_typeid} ) AND contenttypeid IN (#{@post_typeids_string});").first["cnt"]

    batches(BATCH_SIZE) do |offset|
      posts = mysql_query <<-SQL
        SELECT p.nodeid AS postid, p.userid AS userid, p.parentid AS threadid,
            CONVERT(CAST(rawtext AS BINARY)USING utf8) AS raw, p.publishdate AS dateline,
            1 AS visible, p.parentid AS parentid
        FROM #{DB_PREFIX}node p
        LEFT JOIN #{DB_PREFIX}nodeview nv ON nv.nodeid=p.nodeid
        LEFT JOIN #{DB_PREFIX}text txt ON txt.nodeid=p.nodeid
        WHERE p.parentid NOT IN ( select nodeid from #{DB_PREFIX}node where contenttypeid=#{@channel_typeid} )
          AND p.contenttypeid IN (#{@post_typeids_string})
        ORDER BY postid
           LIMIT #{BATCH_SIZE}
          OFFSET #{offset}
      SQL

      break if posts.size < 1

      # disabled line below, caused issues
      # next if all_records_exist? :posts, posts.map {|p| p["postid"] }

      create_posts(posts, total: post_count, offset: offset) do |post|
        raw = preprocess_post_raw(post["raw"])
        next if raw.blank?

        unless topic = topic_lookup_from_imported_post_id("thread-#{post["threadid"]}")
          # This might be a post comment -- a child node of a post (which is a child node of a topic)
          # In this case, we have a different import_id format to check.
          # This will result in post comments being added to topics as additional posts,
          # inlined by timestamp.
          # They are correctly linked as replies to their parent post.
          next unless topic = topic_lookup_from_imported_post_id(post["threadid"])
        end

        p = {
          id: post["postid"],
          user_id: user_id_from_imported_user_id(post["userid"]) || Discourse::SYSTEM_USER_ID,
          topic_id: topic[:topic_id],
          raw: raw,
          created_at: parse_timestamp(post["dateline"]),
          hidden: post["visible"].to_i != 1,
        }
        if parent = topic_lookup_from_imported_post_id(post["parentid"])
          p[:reply_to_post_number] = parent[:post_number]
        end
        p
      end
    end
  end

  def import_attachments
    puts '', 'importing attachments...'

    ext = mysql_query("SELECT GROUP_CONCAT(DISTINCT(extension)) exts FROM #{DB_PREFIX}filedata").first['exts'].split(',')
    SiteSetting.authorized_extensions = (SiteSetting.authorized_extensions.split("|") + ext).uniq.join("|")

    upload_count = mysql_query("SELECT COUNT(nodeid) count FROM #{DB_PREFIX}attach").first['count']

    batches(ATTACHMENT_BATCH_SIZE) do |offset|
      # This query pulls in both attachments and photo gallery items
      # Note that gallery items may not work right if filesystem storage is used;
      # we have to make up a filename for gallery items.
      uploads = mysql_query <<-SQL
      SELECT n.parentid nodeid, a.filename, fd.userid, LENGTH(fd.filedata) AS dbsize, filedata, fd.filedataid
      FROM #{DB_PREFIX}attach a
      LEFT JOIN #{DB_PREFIX}filedata fd ON fd.filedataid = a.filedataid
      LEFT JOIN #{DB_PREFIX}node n on n.nodeid = a.nodeid
      UNION SELECT np.parentid nodeid, CONCAT(fdp.filehash, fdp.extension) AS filename, fdp.userid, LENGTH(fdp.filedata) AS dbsize, filedata, fdp.filedataid
        FROM #{DB_PREFIX}photo p
        LEFT JOIN #{DB_PREFIX}filedata fdp on fdp.filedataid = p.filedataid
        LEFT JOIN #{DB_PREFIX}node np on np.nodeid = p.nodeid
        LIMIT #{ATTACHMENT_BATCH_SIZE}
        OFFSET #{offset}
      SQL

      current_count = 0

      uploads.each do |upload|
        post_id = PostCustomField.where(name: 'import_id').where(value: upload['nodeid']).first&.post_id
        post_id = PostCustomField.where(name: 'import_id').where(value: "thread-#{upload['nodeid']}").first&.post_id unless post_id
        if post_id.nil?
          puts "Post for #{upload['nodeid']} not found"
          next
        end
        post = Post.find(post_id)

        filename = File.join(ATTACH_DIR, upload['userid'].to_s.split('').join('/'), "#{upload['filedataid']}.attach")
        real_filename = upload['filename']
        real_filename.prepend SecureRandom.hex if real_filename[0] == '.'

        unless File.exist?(filename)
          # attachments can be on filesystem or in database
          # try to retrieve from database if the file did not exist on filesystem
          if upload['dbsize'].to_i == 0
            puts "Attachment file #{upload['filedataid']} doesn't exist"
            next
          end

          tmpfile = 'attach_' + upload['filedataid'].to_s
          filename = File.join('/tmp/', tmpfile)
          File.open(filename, 'wb') { |f|
            #f.write(PG::Connection.unescape_bytea(row['filedata']))
            f.write(upload['filedata'])
          }
        end

        upl_obj = create_upload(post.user.id, filename, real_filename)
        if upl_obj&.persisted?
          html = html_for_upload(upl_obj, real_filename)
          if !post.raw[html]
            post.raw += "\n\n#{html}\n\n"
            post.save!
            PostUpload.create!(post: post, upload: upl_obj) unless PostUpload.where(post: post, upload: upl_obj).exists?
          end
        else
          puts "Fail"
          exit
        end
        current_count += 1
        print_status(current_count + (offset || 0), upload_count)
      end
    end
  end

  def close_topics
    puts "", "Closing topics..."

    sql = <<-SQL
      WITH closed_topic_ids AS (
        SELECT t.id AS topic_id
        FROM post_custom_fields pcf
        JOIN posts p ON p.id = pcf.post_id
        JOIN topics t ON t.id = p.topic_id
        WHERE pcf.name = 'import_id'
        AND pcf.value IN (?)
      )
      UPDATE topics
      SET closed = true
      WHERE id IN (SELECT topic_id FROM closed_topic_ids)
    SQL

    DB.exec(sql, @closed_topic_ids)
  end

  def post_process_posts
    puts "", "Postprocessing posts..."

    current = 0
    max = Post.count

    Post.find_each do |post|
      begin
        new_raw = postprocess_post_raw(post.raw)
        if new_raw != post.raw
          post.raw = new_raw
          post.save
        end
      rescue PrettyText::JavaScriptError
        nil
      ensure
        print_status(current += 1, max)
      end
    end
  end

  def preprocess_post_raw(raw)
    return "" if raw.blank?

    # decode HTML entities
    raw = @htmlentities.decode(raw)

    # fix whitespaces
    raw = raw.gsub(/(\\r)?\\n/, "\n")
      .gsub("\\t", "\t")

    # [HTML]...[/HTML]
    raw = raw.gsub(/\[html\]/i, "\n```html\n")
      .gsub(/\[\/html\]/i, "\n```\n")

    # [PHP]...[/PHP]
    raw = raw.gsub(/\[php\]/i, "\n```php\n")
      .gsub(/\[\/php\]/i, "\n```\n")

    # [HIGHLIGHT="..."]
    raw = raw.gsub(/\[highlight="?(\w+)"?\]/i) { "\n```#{$1.downcase}\n" }

    # [CODE]...[/CODE]
    # [HIGHLIGHT]...[/HIGHLIGHT]
    raw = raw.gsub(/\[\/?code\]/i, "\n```\n")
      .gsub(/\[\/?highlight\]/i, "\n```\n")

    # [SAMP]...[/SAMP]
    raw = raw.gsub(/\[\/?samp\]/i, "`")

    # replace all chevrons with HTML entities
    # NOTE: must be done
    #  - AFTER all the "code" processing
    #  - BEFORE the "quote" processing
    raw = raw.gsub(/`([^`]+)`/im) { "`" + $1.gsub("<", "\u2603") + "`" }
      .gsub("<", "&lt;")
      .gsub("\u2603", "<")

    raw = raw.gsub(/`([^`]+)`/im) { "`" + $1.gsub(">", "\u2603") + "`" }
      .gsub(">", "&gt;")
      .gsub("\u2603", ">")

    # [URL=...]...[/URL]
    raw.gsub!(/\[url="?(.+?)"?\](.+?)\[\/url\]/i) { "<a href=\"#{$1}\">#{$2}</a>" }

    # [URL]...[/URL]
    # [MP3]...[/MP3]
    raw = raw.gsub(/\[\/?url\]/i, "")
      .gsub(/\[\/?mp3\]/i, "")

    # [MENTION]<username>[/MENTION]
    raw = raw.gsub(/\[mention\](.+?)\[\/mention\]/i) do
      old_username = $1
      if @old_username_to_new_usernames.has_key?(old_username)
        old_username = @old_username_to_new_usernames[old_username]
      end
      "@#{old_username}"
    end

    # [USER=<user_id>]<username>[/USER]
    raw = raw.gsub(/\[user="?(\d+)"?\](.+?)\[\/user\]/i) do
      user_id, old_username = $1, $2
      if @old_username_to_new_usernames.has_key?(old_username)
        new_username = @old_username_to_new_usernames[old_username]
      else
        new_username = old_username
      end
      "@#{new_username}"
    end

    # [FONT=blah] and [COLOR=blah]
    # no idea why the /i is not matching case insensitive..
    raw.gsub! /\[color=.*?\](.*?)\[\/color\]/im, '\1'
    raw.gsub! /\[COLOR=.*?\](.*?)\[\/COLOR\]/im, '\1'
    raw.gsub! /\[font=.*?\](.*?)\[\/font\]/im, '\1'
    raw.gsub! /\[FONT=.*?\](.*?)\[\/FONT\]/im, '\1'

    # [CENTER]...[/CENTER]
    raw.gsub! /\[CENTER\](.*?)\[\/CENTER\]/im, '\1'

    # fix LIST
    raw.gsub! /\[LIST\](.*?)\[\/LIST\]/im, '<ul>\1</ul>'
    raw.gsub! /\[\*\]/im, '<li>'

    # [QUOTE]...[/QUOTE]
    raw = raw.gsub(/\[quote\](.+?)\[\/quote\]/im) { "\n> #{$1}\n" }

    # [QUOTE=<username>]...[/QUOTE]
    raw = raw.gsub(/\[quote=([^;\]]+)\](.+?)\[\/quote\]/im) do
      old_username, quote = $1, $2

      if @old_username_to_new_usernames.has_key?(old_username)
        old_username = @old_username_to_new_usernames[old_username]
      end
      "\n[quote=\"#{old_username}\"]\n#{quote}\n[/quote]\n"
    end

    # [YOUTUBE]<id>[/YOUTUBE]
    raw = raw.gsub(/\[youtube\](.+?)\[\/youtube\]/i) { "\n//youtu.be/#{$1}\n" }

    # [VIDEO=youtube;<id>]...[/VIDEO]
    raw = raw.gsub(/\[video=youtube;([^\]]+)\].*?\[\/video\]/i) { "\n//youtu.be/#{$1}\n" }

    raw
  end

  def postprocess_post_raw(raw)
    # [QUOTE=<username>;<post_id>]...[/QUOTE]
    raw = raw.gsub(/\[quote=([^;]+);n(\d+)\](.+?)\[\/quote\]/im) do
      old_username, post_id, quote = $1, $2, $3

      if @old_username_to_new_usernames.has_key?(old_username)
        old_username = @old_username_to_new_usernames[old_username]
      end

      if topic_lookup = topic_lookup_from_imported_post_id(post_id)
        post_number = topic_lookup[:post_number]
        topic_id    = topic_lookup[:topic_id]
        "\n[quote=\"#{old_username},post:#{post_number},topic:#{topic_id}\"]\n#{quote}\n[/quote]\n"
      else
        "\n[quote=\"#{old_username}\"]\n#{quote}\n[/quote]\n"
      end
    end

    # remove attachments
    raw = raw.gsub(/\[attach.*?\[\/attach\]/i, "")

    # [THREAD]<thread_id>[/THREAD]
    # ==> http://my.discourse.org/t/slug/<topic_id>
    raw = raw.gsub(/\[thread\](\d+)\[\/thread\]/i) do
      thread_id = $1
      if topic_lookup = topic_lookup_from_imported_post_id("thread-#{thread_id}")
        topic_lookup[:url]
      else
        $&
      end
    end

    # [THREAD=<thread_id>]...[/THREAD]
    # ==> [...](http://my.discourse.org/t/slug/<topic_id>)
    raw = raw.gsub(/\[thread=(\d+)\](.+?)\[\/thread\]/i) do
      thread_id, link = $1, $2
      if topic_lookup = topic_lookup_from_imported_post_id("thread-#{thread_id}")
        url = topic_lookup[:url]
        "[#{link}](#{url})"
      else
        $&
      end
    end

    # [POST]<post_id>[/POST]
    # ==> http://my.discourse.org/t/slug/<topic_id>/<post_number>
    raw = raw.gsub(/\[post\](\d+)\[\/post\]/i) do
      post_id = $1
      if topic_lookup = topic_lookup_from_imported_post_id(post_id)
        topic_lookup[:url]
      else
        $&
      end
    end

    # [POST=<post_id>]...[/POST]
    # ==> [...](http://my.discourse.org/t/<topic_slug>/<topic_id>/<post_number>)
    raw = raw.gsub(/\[post=(\d+)\](.+?)\[\/post\]/i) do
      post_id, link = $1, $2
      if topic_lookup = topic_lookup_from_imported_post_id(post_id)
        url = topic_lookup[:url]
        "[#{link}](#{url})"
      else
        $&
      end
    end

    raw
  end

  def create_permalinks
    puts "", "creating permalinks..."

    current_count = 0
    total_count = mysql_query("SELECT COUNT(nodeid) cnt
        FROM #{DB_PREFIX}node
        WHERE (unpublishdate = 0 OR unpublishdate IS NULL)
        AND (approved = 1 AND showapproved = 1)
        AND parentid IN (
        SELECT nodeid FROM #{DB_PREFIX}node WHERE contenttypeid=#{@channel_typeid} ) AND contenttypeid IN (#{@post_typeids_string});"
    ).first["cnt"]

    batches(BATCH_SIZE) do |offset|
      topics = mysql_query <<-SQL
        SELECT p.urlident p1, f.urlident p2, t.nodeid, t.urlident p3
        FROM #{DB_PREFIX}node f
        LEFT JOIN #{DB_PREFIX}node t ON t.parentid = f.nodeid
        LEFT JOIN #{DB_PREFIX}node p ON p.nodeid = f.parentid
        WHERE f.contenttypeid = #{@channel_typeid}
          AND t.contenttypeid IN (#{@post_typeids_string})
          AND t.approved = 1 AND t.showapproved = 1
          AND (t.unpublishdate = 0 OR t.unpublishdate IS NULL)
        ORDER BY t.nodeid
           LIMIT #{BATCH_SIZE}
          OFFSET #{offset}
      SQL

      break if topics.size < 1

      topics.each do |topic|
        current_count += 1
        print_status current_count, total_count
        disc_topic = topic_lookup_from_imported_post_id("thread-#{topic['nodeid']}")

        Permalink.create(
          url: "#{URL_PREFIX}#{topic['p1']}/#{topic['p2']}/#{topic['nodeid']}-#{topic['p3']}",
          topic_id: disc_topic[:topic_id]
        ) rescue nil
      end
    end

    # cats
    cats = mysql_query <<-SQL
      SELECT nodeid, urlident
      FROM #{DB_PREFIX}node
      WHERE contenttypeid=#{@channel_typeid}
      AND parentid=#{ROOT_NODE};
    SQL
    cats.each do |c|
      category_id = CategoryCustomField.where(name: 'import_id').where(value: c['nodeid']).first.category_id
      Permalink.create(url: "#{URL_PREFIX}#{c['urlident']}", category_id: category_id) rescue nil
    end

    # subcats
    subcats = mysql_query <<-SQL
      SELECT n1.nodeid,n2.urlident p1,n1.urlident p2
      FROM #{DB_PREFIX}node n1
      LEFT JOIN #{DB_PREFIX}node n2 ON n2.nodeid=n1.parentid
      WHERE n2.parentid = #{ROOT_NODE}
      AND n1.contenttypeid=#{@channel_typeid};
    SQL
    subcats.each do |sc|
      category_id = CategoryCustomField.where(name: 'import_id').where(value: sc['nodeid']).first&.category_id
      next unless category_id
      Permalink.create(url: "#{URL_PREFIX}#{sc['p1']}/#{sc['p2']}", category_id: category_id) rescue nil
    end
  end

  def import_tags
    puts "", "importing tags..."

    SiteSetting.tagging_enabled = true
    SiteSetting.max_tags_per_topic = 100
    staff_guardian = Guardian.new(Discourse.system_user)

    records = mysql_query(<<~SQL
      SELECT nodeid, GROUP_CONCAT(tagtext) tags
      FROM #{DB_PREFIX}tag t
      LEFT JOIN #{DB_PREFIX}tagnode tn ON tn.tagid = t.tagid
      WHERE t.tagid IS NOT NULL
      AND tn.nodeid IS NOT NULL
      GROUP BY nodeid
    SQL
    ).to_a

    current_count = 0
    total_count = records.count

    records.each do |rec|
      current_count += 1
      print_status current_count, total_count
      tl = topic_lookup_from_imported_post_id("thread-#{rec['nodeid']}")
      next if tl.nil?   # topic might have been deleted

      topic = Topic.find(tl[:topic_id])
      tag_names = rec['tags'].force_encoding("UTF-8").split(',')
      DiscourseTagging.tag_topic_by_names(topic, staff_guardian, tag_names)
    end
  end

  def parse_timestamp(timestamp)
    Time.zone.at(@tz.utc_to_local(Time.at(timestamp)))
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::VBulletin.new.perform
