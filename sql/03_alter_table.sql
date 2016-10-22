alter table `rooms` add (
  `owner_id` bigint(20) NOT NULL
);

update rooms, room_owners set rooms.owner_id = room_owners.token_id where rooms.id = rooms_owners.room_id;
