# Fine Training accepts up to 200 files per batch. Rack validates multipart
# requests before Rails controllers run, so keep these parser limits above the
# application-level cap.
Rack::Utils.multipart_file_limit = 250 if Rack::Utils.respond_to?(:multipart_file_limit=)
Rack::Utils.multipart_part_limit = 300 if Rack::Utils.respond_to?(:multipart_part_limit=)
Rack::Utils.multipart_total_part_limit = 4_096 if Rack::Utils.respond_to?(:multipart_total_part_limit=)
