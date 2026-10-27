# Enforce one container registry cleanup policy on every project that has
# container images. GitLab has no instance-wide default, so this runs daily via
# gitlab-registry-cleanup-policy.timer to cover projects that start pushing.
# Projects without images are skipped: GitLab's ContainerExpirationPolicyWorker
# disables their policies daily (disable_policies_without_container_repositories).
# Deleted tags are reclaimed by the registry metadata database's online GC.
POLICY = {
  enabled: true,
  cadence: '1d',
  keep_n: 5,
  older_than: '7d',
  name_regex: '.*',
  name_regex_keep: 'latest'
}.freeze

changed = 0
failed = 0
Project.where(id: ContainerRepository.select(:project_id)).includes(:container_expiration_policy).find_each do |project|
  policy = project.container_expiration_policy || project.build_container_expiration_policy
  policy.assign_attributes(POLICY)
  next unless policy.changed?

  if policy.save
    changed += 1
  else
    failed += 1
    warn "FAIL #{project.full_path}: #{policy.errors.full_messages.join(', ')}"
  end
end

puts "registry cleanup policy: changed=#{changed} failed=#{failed}"

# Build-cache repositories (`<image>/cache`) get one tag per CI build, and
# project policies cannot expire anything younger than 7d, so they are pruned
# here to the newest CACHE_KEEP_N tags once tags are older than CACHE_OLDER_THAN.
CACHE_KEEP_N = 5
CACHE_OLDER_THAN = '1d'
CACHE_MAX_PASSES = 50 # each pass deletes at most the service's list-size limit

cache_deleted = 0
cache_failed = 0
ContainerRepository.includes(:project).where("container_repositories.name = 'cache' OR container_repositories.name LIKE '%/cache'").find_each do |repo|
  CACHE_MAX_PASSES.times do
    result = Projects::ContainerRepository::CleanupTagsService.new(
      container_repository: repo,
      current_user: nil,
      params: {
        'name_regex_delete' => '.*',
        'keep_n' => CACHE_KEEP_N,
        'older_than' => CACHE_OLDER_THAN,
        'container_expiration_policy' => true
      }
    ).execute

    if result[:status] != :success
      cache_failed += 1
      warn "FAIL #{repo.path}: #{result[:message]}"
      break
    end

    deleted = Array(result[:deleted]).size
    cache_deleted += deleted
    break if deleted.zero?
  end
end

puts "registry cache pruning: deleted_tags=#{cache_deleted} failed=#{cache_failed}"
exit(failed.zero? && cache_failed.zero? ? 0 : 1)
