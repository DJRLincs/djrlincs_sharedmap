-- =============================================================================
-- DJRLincs Shared Map - Database Migration
-- Run this SQL to set up the required database table
-- =============================================================================

CREATE TABLE IF NOT EXISTS `djrlincs_sharedmaps` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `map_name` VARCHAR(64) NOT NULL UNIQUE,
    `excalidraw_data` LONGTEXT COMMENT 'JSON data from Excalidraw',
    `last_editor_charid` INT DEFAULT NULL,
    `last_editor_name` VARCHAR(128) DEFAULT NULL,
    `locked_by_charid` INT DEFAULT NULL,
    `locked_by_name` VARCHAR(128) DEFAULT NULL,
    `locked_at` DATETIME DEFAULT NULL,
    `created_at` DATETIME DEFAULT CURRENT_TIMESTAMP,
    `updated_at` DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    INDEX `idx_locked_by` (`locked_by_charid`),
    INDEX `idx_map_name` (`map_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Insert default map
INSERT IGNORE INTO `djrlincs_sharedmaps` (`map_name`, `excalidraw_data`) 
VALUES ('Main Planning Map', '{"elements":[],"appState":{}}');
